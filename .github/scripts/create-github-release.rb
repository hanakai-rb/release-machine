#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: create-github-release.rb <repo> <release-tag> <github-token>
#
# Creates a GitHub release entry for the given release tag, using content from the repo's
# CHANGELOG.md.

require "bundler/inline"

gemfile do
  source "https://gem.coop"
  gem "changelog-parser"
end

require "json"
require "net/http"
require "uri"

repo = ARGV[0] or abort "ERROR: Repository required (e.g. dry-rb/dry-operation)"
tag = ARGV[1] or abort "ERROR: Tag required (e.g. v1.0.0)"
github_token = ARGV[2] or abort "ERROR: GitHub token required"

version = tag.sub(/^v/, "")
is_prerelease = tag.include?("alpha") || tag.include?("beta") || tag.include?("rc")

changelog_body = ""
begin
  if File.exist?("CHANGELOG.md")
    parser = Changelog::Parser.new(File.read("CHANGELOG.md"))
    version_data = parser[version]

    if version_data && version_data[:content]
      changelog_body = version_data[:content].strip

      # If the changelog body contains a Markdown URL reference for a GitHub compare URL, then
      # expose that as a convenience for the reader.
      #
      # For example, detect this:
      #   [1.7.0]: https://github.com/org/repo/compare/v1.6.0...v1.7.0
      #
      # And produce this:
      #   [1.7.0]: https://github.com/org/repo/compare/v1.6.0...v1.7.0
      #   [Compare v1.6.0...v1.7.0][1.7.0]
      #
      if changelog_body =~ /\[#{Regexp.escape(version)}\]:.+\/compare\/v?(.+?)\.\.\.v?#{Regexp.escape(version)}/
        previous_version = $1

        if !previous_version.to_s.empty?
          comparison_link = "\n[Compare v#{previous_version} ... v#{version}][#{version}]"
          changelog_body += comparison_link
        end
      end
    else
      puts "WARNING: No changelog entry found for version #{version}"
    end
  else
    puts "WARNING: CHANGELOG.md not found"
  end
rescue => e
  puts "WARNING: Changelog parsing failed: #{e.message}"
  puts "Creating release with empty body"
end

payload = {
  tag_name: tag,
  name: tag,
  body: changelog_body,
  draft: false,
  prerelease: is_prerelease
}

uri = URI("https://api.github.com/repos/#{repo}/releases")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true

request = Net::HTTP::Post.new(uri.path)
request["Accept"] = "application/vnd.github+json"
request["Authorization"] = "Bearer #{github_token}"
request.body = JSON.generate(payload)

response = http.request(request)
if response.code == "201"
  release_data = JSON.parse(response.body)
  puts "Created release: #{release_data["html_url"]}"
  exit 0
else
  puts "ERROR: GitHub API returned HTTP #{response.code}"
  puts "Response: #{response.body}"
  exit 1
end
