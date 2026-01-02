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
