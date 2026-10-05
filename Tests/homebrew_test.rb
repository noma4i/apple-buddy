require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class HomebrewTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "Scripts/update-homebrew.rb")

  def test_update_pins_the_source_and_uses_the_release_version
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "Formula"))
      FileUtils.mkdir_p(File.join(directory, "Sources/notes-buddy"))
      File.write(File.join(directory, "Sources/notes-buddy/NotesBuddy.swift"), '    static let releaseVersion = "1.0.0"')
      target = File.join(directory, "Formula/nb.rb")
      FileUtils.cp(File.join(ROOT, "Formula/nb.rb"), target)
      sha = "a" * 40
      output, status = Open3.capture2e("ruby", SCRIPT, sha, chdir: directory)
      assert status.success?, output
      content = File.read(target)
      assert_includes content, 'revision: "' + sha + '"'
      assert_includes content, 'version "1.0.0"'
      assert_includes content, 'system "swift", "build", "-c", "release", "--disable-sandbox"'
      assert_includes content, 'bin.install ".build/release/nb"'
      original = content
      output, status = Open3.capture2e("ruby", SCRIPT, sha, chdir: directory)
      assert status.success?, output
      assert_equal original, File.read(target)
      output, status = Open3.capture2e("ruby", SCRIPT, "not-a-sha", chdir: directory)
      refute status.success?, output
      assert_equal original, File.read(target)
    end
  end
end
