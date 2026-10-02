require_relative "graphics"

module Media
  # Native Swift rendering only. PNG sequences are an explicit preview/export option.
  class Anim < Graphics
    def render(scene, out, **options)
      raise ArgumentError, "Animation scenes must be .json; JavaScript rendering has been removed. See tools/graphics/README.md" unless File.extname(scene).downcase == ".json"
      super
    end
  end
end
