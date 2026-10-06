class Nb < Formula
  desc "Read, search, edit and organize Apple Notes"
  homepage "https://github.com/noma4i/notes-buddy"
  url "https://github.com/noma4i/notes-buddy.git", revision: "4c13115576ce0e232690f8391f3f87c539d855b6"
  version "1.0.0"

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
    assert_equal version.to_s, shell_output("#{bin}/nb version").strip
    assert_match "USAGE: nb", shell_output("#{bin}/nb help")
    assert_match "USAGE: nb search", shell_output("#{bin}/nb search help")
  end
end
