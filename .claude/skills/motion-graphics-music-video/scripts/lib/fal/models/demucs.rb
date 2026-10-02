require_relative "base"

module Fal
  module Models
    # https://fal.ai/models/fal-ai/demucs: music source separation into stems (vocals, drums, bass, other, …). The vocal stem drives
    # audio analysis and local character timing without instrumental bleed.
    class Demucs < Base
      ENDPOINT = "fal-ai/demucs".freeze
      DEFAULTS = { model: "htdemucs_ft", output_format: "wav" }.freeze

      def separate(audio_url:, **opts)
        call(audio_url: audio_url, **opts)
      end
    end
  end
end
