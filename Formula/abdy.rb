class Abdy < Formula
  desc "Read, search, edit and organize Apple Notes, Reminders and Calendar"
  homepage "https://github.com/noma4i/apple-buddy"
  url "https://github.com/noma4i/apple-buddy.git", revision: "ba599d89193e3945954ffd8457eb6bece2b0cce0"
  version "1.0.0"

  depends_on :macos

  def install
    %w[cache config security].each { |name| (buildpath/".build"/name).mkpath }
    system "swift", "build", "-c", "release", "--disable-sandbox",
           "--cache-path", ".build/cache",
           "--config-path", ".build/config",
           "--security-path", ".build/security"
    bin.install ".build/release/abdy"
    bin.install_symlink "abdy" => "nb"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/abdy version").strip
    assert_match "USAGE: abdy", shell_output("#{bin}/abdy help")
    assert_match "USAGE: abdy notes search", shell_output("#{bin}/abdy notes search help")
    assert_match "USAGE: abdy notes search", shell_output("#{bin}/nb search help")
  end
end
