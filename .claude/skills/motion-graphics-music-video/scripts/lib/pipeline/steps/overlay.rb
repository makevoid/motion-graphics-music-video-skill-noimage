module Pipeline
  module Steps
    # Step 5: native Swift scene composition over a video or still plate.
    # Only the final movie is persisted; frame buffers/layers/audio stay in memory.
    class Overlay < Step
      MODEL = Fal::Models::Whisper
      OUT = "final_overlay.mp4".freeze

      def submit
        MODEL.new(client: client).transcribe(audio_url: project.fetch!(:music, :url), chunk_level: "word")
      end

      def materialize(result)
        words = Array(result.output["chunks"]).map { |c| { w: c["text"].to_s.strip, s: c.dig("timestamp", 0), e: c.dig("timestamp", 1) } }
        File.write(data_path(:words), JSON.pretty_generate(words))
        track!
        base_data(result).merge(render!)
      end

      # Reuse approved global word timings without another paid transcription.
      def prepare!(words_path = nil)
        raw = words_path ? JSON.parse(File.read(words_path)) : []
        chunks = raw.is_a?(Array) ? raw : raw.fetch("chunks") { raw.fetch("words", []) }
        offset = project.generation.fetch(:music_offset, 0)
        words = chunks.filter_map do |chunk|
          first = chunk["s"] || chunk.dig("timestamp", 0) || chunk["start"]
          last = chunk["e"] || chunk.dig("timestamp", 1) || chunk["end"]
          next unless first && last && last > offset && first < offset + project.duration
          { w: (chunk["w"] || chunk["text"] || chunk["word"]).to_s.strip,
            s: [first - offset, 0].max, e: [last - offset, project.duration].min }
        end
        File.write(data_path(:words), JSON.pretty_generate(words))
        track!
        { words: data_path(:words), count: words.size, local_offset: offset }
      end

      # Render all frames and composite, from the saved words.json / track files (no fal call): rake anim:overlay.
      def render!
        require "securerandom"
        target = project.path(OUT)
        temporary = project.path(".overlay-#{SecureRandom.hex(8)}.mp4")
        begin
          summary = anim.render(sketch, temporary, **plate_format, data: data_files, plate: plate,
                                audio: still_plate? ? project.fetch!(:music, :path) : nil, coverage: true)
          FileUtils.mv(temporary, target)
        ensure
          FileUtils.rm_f(temporary)
        end
        data = { path: target, sketch: sketch, render_ms: summary["ms"], rendered_frames: summary["frames"],
                 coverage_pct_by_frame: summary["coverage_pct_by_frame"], backend: "swift" }
        project.record(key, data.merge(review: nil))
        data
      end

      # Render only `frames` and composite each over its plate frame into one board: rake anim:preview[0,48,96].
      def preview!(frames)
        dir = project.path("05_overlay", "preview")
        anim.render(sketch, dir, **plate_format, data: data_files, only: frames, plate: plate)
        stills = frames.map do |i|
          [File.join(dir, format("%04d.png", i)), format("f%d  %.2fs", i, i.to_f / plate_format[:fps])]
        end
        magick.board(stills, project.review_path(key, "preview.jpg"), tile: "#{[stills.size, 3].min}x", width: 960).tap { |b| puts b }
      end

      def review
        final = project[key]["path"]
        summary = ffmpeg.summary(final)
        rendered_frames = project[key]["rendered_frames"]
        coverage = project[key].fetch("coverage_pct_by_frame", {})
        compare = ffmpeg.hstack(reference, final, project.review_path(key, "reference_vs_overlay.mp4")) if reference
        {
          summary: summary, contact_sheet: ffmpeg.contact_sheet(final, project.review_path(key, "contact_sheet.jpg"), cols: 6, rows: 3),
          coverage_pct_by_frame: coverage, compare: compare,
          **verdict(
            "same length as plate" => [(summary[:duration] - project.duration).abs < 0.05, "#{summary[:duration]}s"],
            "every plate frame rendered" => [rendered_frames == plate_format[:frames] && summary.dig(:video, :frames) == plate_format[:frames], "#{rendered_frames}/#{plate_format[:frames]} encoded frames"],
            "audio kept" => [summary.dig(:audio, :codec) == "aac", summary[:audio].inspect],
            "overlay present" => [!coverage.empty? && coverage.values.count(&:positive?) >= coverage.size * 0.8, "#{coverage.values.count(&:positive?)}/#{coverage.size} sampled frames have graphics"],
            # a still plate is just paper: the sketch is the picture
            "plate not buried" => [still_plate? || (coverage.values.max || 0) < 45, "max coverage #{coverage.values.max}%"]
          )
        }
      end

      protected

      def anim = @anim ||= Media::Anim.new

      private

      def sketch = project.prompt_path("05_overlay")
      # The video to draw on: a held keyframe (plate:), the multi-shot plate, or the single-shot video.
      def plate
        return project.fetch!(project.step?(Shots) ? :shots : :video, :path) unless still_plate?
        project.keyframe(project.generation[:plate])["path"]
      end

      def still_plate? = !!project.generation[:plate]
      def reference = project.generation[:reference]&.then { |f| File.join(ROOT, f) }
      def data_path(name) = project.path("05_overlay", "#{name}.json")
      def tracks = project.generation.fetch(:track, {})

      def data_files
        files = { words: data_path(:words), **tracks.keys.to_h { |name| [name, data_path(name)] } }
        if project.step?(Clips)
          clips = project.fetch!(:clips, :items).transform_values { |item| JSON.parse(File.read(item["path"])).slice("dir", "frames", "w", "h", "audio_at", "box", "src") }
          File.write(data_path(:clips), JSON.pretty_generate(clips))
          files[:clips] = data_path(:clips)
        end
        return files unless project.step?(Shots)
        shots = Shots.new(project: project).specs.map { |name, s| { name: name, start_frame: s["start_frame"], frames: s["frames"] } }
        File.write(data_path(:shots), JSON.pretty_generate(shots))
        files.merge(shots: data_path(:shots))
      end

      def track!
        tracks.each do |name, (x, y, size, search, from)|
          result = if still_plate?
            format = plate_format
            { fps: format[:fps], width: format[:width], height: format[:height],
              points: Array.new(format[:frames]) { |frame| [x, y, frame < (from || 0) ? 0.0 : 1.0] } }
          else
            python.track_template(plate, x, y, size, search || size, from || 0)
          end
          File.write(data_path(name), JSON.generate(result))
        end
      end

      def plate_format
        return { width: 1920, height: 1080, fps: Clips::FPS, frames: (project.duration * Clips::FPS).round } if still_plate?
        @plate_format ||= ffmpeg.summary(plate).then do |s|
          { width: s.dig(:video, :w), height: s.dig(:video, :h), fps: s.dig(:video, :fps),
            frames: s.dig(:video, :frames) || (s[:duration] * s.dig(:video, :fps)).round }
        end
      end
    end
  end
end
