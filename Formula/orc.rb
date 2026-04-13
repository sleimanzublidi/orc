class Orc < Formula
  desc "CLI for orchestrating AI agents via YAML-defined workflows"
  homepage "https://github.com/sleimanzublidi/orc"
  license "MIT"
  version "1.0.0"

  url "https://github.com/sleimanzublidi/orc/releases/download/v#{version}/release-orc-cli-universal-#{version}.zip"
  sha256 "PLACEHOLDER"

  depends_on :macos

  head "https://github.com/sleimanzublidi/orc.git", branch: "main"

  def install
    if build.head?
      cd "Orc" do
        system "swift", "build", "-c", "release", "--disable-sandbox"
        bin.install ".build/release/orc"
      end
    else
      bin.install "orc-cli-#{version}/bin/orc"
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/orc version")
  end
end
