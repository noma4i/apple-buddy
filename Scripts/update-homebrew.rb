sha, count = ARGV
abort "Usage: update-homebrew.rb COMMIT_SHA POSITIVE_COMMIT_COUNT" unless ARGV.length == 2 && sha.match?(/\A[0-9a-f]{40}\z/) && count.match?(/\A[1-9][0-9]*\z/)

file = "Formula/nb.rb"
content = File.read(file)
revision = /revision: "[0-9a-f]{40}"/
version = /^  version "0\.0\.[0-9]+"$/
abort "Formula must contain exactly 1 source revision and version" unless content.scan(revision).length == 1 && content.scan(version).length == 1
content = content.sub(revision, 'revision: "' + sha + '"').sub(version, '  version "0.0.' + count + '"')
File.write(file, content)
