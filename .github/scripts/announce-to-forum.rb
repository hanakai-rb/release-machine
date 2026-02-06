#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: announce-to-forum.rb <gem-name> <repo> <tag>
#
# Fetches a GitHub release and posts an announcement to Discourse forum.
#
# Arguments:
#   gem-name - Name of the gem being released
#   repo     - GitHub repository in owner/repo format
#   tag      - Release tag (e.g., v1.0.0)
#
# Required environment variables:
#   FORUM_URL         - Discourse forum URL
#   FORUM_CATEGORY_ID - Forum category ID for posts
#   FORUM_API_KEY     - Discourse API key
#   GITHUB_TOKEN      - GitHub token (optional for public repos)

require "bundler/inline"

gemfile do
  source "https://gem.coop"
  gem "http"
end

require "json"

# Prepare input
gem_name = ARGV[0] or abort "ERROR: Gem name required"
repo = ARGV[1] or abort "ERROR: Repository required (format: owner/repo)"
tag = ARGV[2] or abort "ERROR: Release tag required"

owner, repo_name = repo.split("/")
abort "ERROR: Invalid repository format. Expected owner/repo" unless owner && repo_name

forum_url = ENV["FORUM_URL"] or abort "ERROR: FORUM_URL env var required"
category_id = ENV["FORUM_CATEGORY_ID"] or abort "ERROR: FORUM_CATEGORY_ID env var required"
api_key = ENV["FORUM_API_KEY"] or abort "ERROR: FORUM_API_KEY secret required"
github_token = ENV["GITHUB_TOKEN"] # Optional

# Fetch release from GitHub
github_response = HTTP
  .tap { _1.auth("Bearer #{github_token}") if github_token }
  .get("https://api.github.com/repos/#{owner}/#{repo_name}/releases/tags/#{tag}")

unless github_response.status.success?
  puts "ERROR: GitHub API returned HTTP #{github_response.code}"
  puts "Response: #{github_response.body}"
  exit 1
end

release_data = github_response.parse
release_url = release_data["html_url"]
release_body = release_data["body"] || ""
version = release_data["tag_name"].sub(/^v/, "")

# Linkify GitHub references in the release notes, but only within parentheses at the end of lines.
# In our conventional CHANGELOG format, this is where we include GitHub references.
#
# Taking this approach means we don't have to worry about incorrect linking in other parts of the
# release notes.

# Matches "(@username in #15)" parentheticals at the end of our release note bullets.
CLOSING_PARENS_REGEXP = /
  ^        # start of line
  (-.*)    # capture: dash and everything up to the opening paren
  \(       # opening paren
  ([^)]+)  # capture: content inside parentheses
  \)       # closing paren
  \s*      # optional trailing whitespace
  $        # end of line
/x

# Matches "@username" mentions.
GITHUB_USERNAME_REGEXP = /(?<!\w)@([a-zA-Z0-9](?:[a-zA-Z0-9]|-(?=[a-zA-Z0-9])){0,38})(?!\w)/
# Matches PR/issue numbers like "#123".
GITHUB_ISSUE_REGEXP = /(?<!\w)#(\d+)(?!\w)/
# Matches commit SHAs (7-40 hex characters).
GITHUB_COMMIT_REGEXP = /(?<!\w)([0-9a-f]{7,40})(?!\w)/

release_body.gsub!(CLOSING_PARENS_REGEXP) do
  prefix = $1
  content = $2

  content.gsub!(GITHUB_USERNAME_REGEXP) do
    username = $1
    "[@#{username}](https://github.com/#{username})"
  end

  content.gsub!(GITHUB_ISSUE_REGEXP) do
    number = $1
    "[##{number}](https://github.com/#{owner}/#{repo_name}/pull/#{number})"
  end

  content.gsub!(GITHUB_COMMIT_REGEXP) do
    sha = $1
    "[`#{sha[0, 7]}`](https://github.com/#{owner}/#{repo_name}/commit/#{sha})"
  end

  "#{prefix}(#{content})"
end

# Prepare forum post
title = "#{gem_name} #{version} released"

body = release_body.strip
body += "\n\n---\n\n"
body += "[View release on GitHub](#{release_url})"

json = {title:, raw: body, category: category_id.to_i}

# Post to Discourse
forum_response = HTTP
  .headers("Content-Type" => "application/json", "Api-Key" => api_key)
  .post("#{forum_url}/posts.json", json:)

if forum_response.status.success?
  post_data = forum_response.parse
  topic_id = post_data["topic_id"]
  post_url = "#{forum_url}/t/#{topic_id}"
  puts "Posted to Discourse: #{post_url}"
  exit 0
else
  puts "ERROR: Discourse API returned HTTP #{forum_response.code}"
  puts "Response: #{forum_response.body}"
  exit 1
end
