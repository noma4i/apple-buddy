require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class HomebrewTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "Scripts/update-homebrew.rb")

  def test_update_pins_the_source_and_advances_the_version
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "Formula"))
      target = File.join(directory, "Formula/nb.rb")
      FileUtils.cp(File.join(ROOT, "Formula/nb.rb"), target)
      sha = "a" * 40
      output, status = Open3.capture2e("ruby", SCRIPT, sha, "42", chdir: directory)
      assert status.success?, output
      content = File.read(target)
      assert_includes content, 'revision: "' + sha + '"'
      assert_includes content, 'version "0.0.42"'
      assert_includes content, 'system "swift", "build", "-c", "release", "--disable-sandbox"'
      assert_includes content, 'bin.install ".build/release/nb"'
      original = content
      output, status = Open3.capture2e("ruby", SCRIPT, sha, "42", chdir: directory)
      assert status.success?, output
      assert_equal original, File.read(target)
      output, status = Open3.capture2e("ruby", SCRIPT, "not-a-sha", "43", chdir: directory)
      refute status.success?, output
      assert_equal original, File.read(target)
    end
  end
end
