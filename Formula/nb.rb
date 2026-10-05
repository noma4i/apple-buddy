class Nb < Formula
  desc "Read, search, edit and organize Apple Notes"
  homepage "https://github.com/noma4i/notes-buddy"
  url "https://github.com/noma4i/notes-buddy.git", revision: "e1635896b542d7d200fa7e3c8739770673c0e633"
  version "0.0.1"

  depends_on :macos

  def install
    %w[cache config security].each { |name| (buildpath/".build"/name).mkpath }
    system "swift", "build", "-c", "release", "--disable-sandbox",
           "--cache-path", ".build/cache",
           "--config-path", ".build/config",
           "--security-path", ".build/security"
    bin.install ".build/release/nb"
  end

  test do
    assert_match "USAGE: nb", shell_output("#{bin}/nb help")
    assert_match "USAGE: nb search", shell_output("#{bin}/nb search help")
  end
end
