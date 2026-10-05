sha = ARGV.first
abort "Usage: update-homebrew.rb COMMIT_SHA" unless ARGV.length == 1 && sha.match?(/\A[0-9a-f]{40}\z/)
source = File.read("Sources/notes-buddy/NotesBuddy.swift")
releases = source.scan(/^    static let releaseVersion = "([0-9]+\.[0-9]+\.[0-9]+)"$/).flatten
abort "Source must contain exactly 1 release version" unless releases.length == 1

file = "Formula/nb.rb"
content = File.read(file)
revision = /revision: "[0-9a-f]{40}"/
version = /^  version "[0-9]+\.[0-9]+\.[0-9]+"$/
abort "Formula must contain exactly 1 source revision and version" unless content.scan(revision).length == 1 && content.scan(version).length == 1
content = content.sub(revision, 'revision: "' + sha + '"').sub(version, '  version "' + releases.first + '"')
File.write(file, content)
