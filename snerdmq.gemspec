lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "snerdmq"
  spec.version       = "0.3.5"
  spec.authors       = ["Greyhands2"]
  spec.email         = ["developer@example.com"]

  spec.summary       = "A zero-config, persistent background job queue for Ruby."
  spec.description   = "The official Ruby SDK for the SnerdMQ Rust daemon. Execute robust, lightning-fast background jobs without Redis."
  spec.homepage      = "https://github.com/speed-nerd/snerdmq-ruby"
  spec.license       = "MIT"

  spec.files         = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "bin"
  spec.executables   = ["snerdmq-install"]
  spec.require_paths = ["lib"]


  spec.add_dependency "rack"
  spec.add_dependency "puma"
  spec.add_dependency "faye-websocket"
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
end
