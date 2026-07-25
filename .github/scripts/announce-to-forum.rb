#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: announce-to-forum.rb <package-name> <repo> <tag> [label]
#
# Fetches a GitHub release and posts an announcement to Discourse forum.
#
# Announcements are grouped into one topic per x.y series, with each x.y.z release posted as a
# reply, so a release of many packages doesn't flood the category with topics. See #topic_title for
# the grouping rules.
#
# Arguments:
#   package-name - Name of the package being released
#   repo         - GitHub repository in owner/repo format
#   tag          - Release tag (e.g., v1.0.0)
#   label        - Optional label to include after the post heading (e.g. "npm"),
#                  rendered as "package-name version (label)"
#
# Required environment variables:
#   FORUM_URL         - Discourse forum URL
#   FORUM_CATEGORY_ID - Forum category ID for posts
#   FORUM_API_KEY     - Discourse API key
#   GITHUB_TOKEN      - GitHub token (optional for public repos)
#
# Optional environment variables:
#   DRY_RUN           - When set, print the topic and post that would be created, and exit without
#                       writing to the forum. The forum env vars above become optional; without
#                       them, the topic lookup is skipped.

require "bundler/inline"

gemfile do
  source "https://gem.coop"
  gem "http"
end

require "json"

# Prepare input
package_name = ARGV[0] or abort "ERROR: Package name required"
repo = ARGV[1] or abort "ERROR: Repository required (format: owner/repo)"
tag = ARGV[2] or abort "ERROR: Release tag required"
label = ARGV[3].to_s.strip # Optional; empty when omitted

owner, repo_name = repo.split("/")
abort "ERROR: Invalid repository format. Expected owner/repo" unless owner && repo_name

DRY_RUN = !ENV["DRY_RUN"].to_s.empty?

FORUM_URL = ENV["FORUM_URL"]
FORUM_CATEGORY_ID = ENV["FORUM_CATEGORY_ID"]
FORUM_API_KEY = ENV["FORUM_API_KEY"]

# Whether we can talk to the forum at all. Only ever false during a dry run. Unset secrets and env
# vars arrive as empty strings, so treat blank as missing.
FORUM_CONFIGURED = [FORUM_URL, FORUM_CATEGORY_ID, FORUM_API_KEY].none? { _1.to_s.strip.empty? }

unless DRY_RUN || FORUM_CONFIGURED
  abort "ERROR: FORUM_URL env var required" if FORUM_URL.to_s.strip.empty?
  abort "ERROR: FORUM_CATEGORY_ID env var required" if FORUM_CATEGORY_ID.to_s.strip.empty?
  abort "ERROR: FORUM_API_KEY secret required" if FORUM_API_KEY.to_s.strip.empty?
end

github_token = ENV["GITHUB_TOKEN"] # Optional

# How many pages of the category's topic listing to search for an existing topic.
MAX_TOPIC_PAGES = 20
# Maximum seconds to wait before creating a topic, so concurrent runs don't create in lockstep.
CREATE_JITTER_SECONDS = 5
# Seconds to wait before checking whether a concurrent run created a duplicate of our new topic.
DUPLICATE_SETTLE_SECONDS = 5

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
  ^               # start of line
  (               # capture: line prefix up to opening paren
    (?:-|[ \t]+)  # dash bullet OR continuation-line indent
    .*
  )
  \(              # opening paren
  ([^)]+)         # capture: content inside parentheses
  \)              # closing paren
  [ \t]*          # match but don't capture trailing spaces or tabs (not newlines)
  $               # end of line
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

# The topic collecting every release in a package's x.y series.
#
# All Hanami gems share a single topic per series, since they're released together as one Hanami x.y
# release: "Hanami 3.0 released" for hanami, hanami-action, hanami-assets, etc. Every other package
# gets its own: "dry-types 1.9 released".
#
# Prereleases are kept out of the way in their own topic, e.g. "Hanami 3.0 (preview) released".
def topic_title(package_name, version)
  series = version[/\A\d+\.\d+/] or abort "ERROR: Could not determine x.y series from version #{version}"

  title =
    if package_name == "hanami" || package_name.start_with?("hanami-")
      "Hanami #{series}"
    else
      "#{package_name} #{series}"
    end

  # Anything beyond digits and dots marks a prerelease, covering both the gem ("3.0.0.rc1") and npm
  # ("3.0.0-rc.1") spellings.
  title += " (preview)" if version.match?(/[^\d.]/)

  "#{title} released"
end

def forum_http
  HTTP.headers("Content-Type" => "application/json", "Api-Key" => FORUM_API_KEY)
end

def abort_on_forum_error(response, action)
  return if response.status.success?

  puts "ERROR: Discourse API returned HTTP #{response.code} when #{action}"
  puts "Response: #{response.body}"
  exit 1
end

def category_slug
  @category_slug ||= begin
    response = forum_http.get("#{FORUM_URL}/c/#{FORUM_CATEGORY_ID}/show.json")
    abort_on_forum_error(response, "looking up category #{FORUM_CATEGORY_ID}")
    response.parse.dig("category", "slug")
  end
end

# Returns topics in our category with exactly this title, oldest first.
#
# This walks the category's topic listing rather than using /search.json, because Discourse's search
# index updates asynchronously and we need to see topics created moments ago (see the race handling
# below).
def find_topics(title)
  topics = []
  page = 0

  while page < MAX_TOPIC_PAGES
    response = forum_http.get("#{FORUM_URL}/c/#{category_slug}/#{FORUM_CATEGORY_ID}.json?page=#{page}")
    abort_on_forum_error response, "listing topics in category #{FORUM_CATEGORY_ID}"

    topic_list = response.parse["topic_list"]
    topics.concat(topic_list["topics"].to_a.select { _1["title"] == title })

    break unless topic_list["more_topics_url"]
    page += 1
  end

  # Sorted by id so callers can take the oldest, which is what makes concurrent runs converge on the
  # same topic.
  topics.sort_by { _1["id"] }
end

# Returns the new topic, or nil if Discourse rejected the title as already used.
def create_topic(title, body)
  json = {title:, raw: body, category: FORUM_CATEGORY_ID.to_i}
  response = forum_http.post("#{FORUM_URL}/posts.json", json:)

  return nil if !response.status.success? && duplicate_title?(response)

  abort_on_forum_error response, "creating topic #{title.inspect}"
  response.parse
end

def duplicate_title?(response)
  errors = begin
    JSON.parse(response.body.to_s)["errors"]
  rescue JSON::ParserError
    nil
  end

  errors.to_a.any? { _1.to_s.match?(/title has already been used/i) }
end

def topic_url(topic_id)
  "#{FORUM_URL}/t/#{topic_id}"
end

def reply_to_topic(topic_id, body)
  response = forum_http.post("#{FORUM_URL}/posts.json", json: {topic_id:, raw: body})
  abort_on_forum_error response, "replying to topic #{topic_id}"

  post = response.parse
  "#{topic_url(topic_id)}/#{post["post_number"]}"
end

def delete_topic(topic_id)
  response = forum_http.delete("#{FORUM_URL}/t/#{topic_id}.json")

  unless response.status.success?
    # Not fatal: the announcement still goes into the topic we're keeping, leaving an empty
    # duplicate behind for manual cleanup. Warn on stderr so this never reaches the workflow's
    # capture of the post URL from stdout.
    warn "WARNING: Could not delete duplicate topic #{topic_id} (HTTP #{response.code}): #{response.body}"
  end

  response.status.success?
end

# Returns the topic for this release series, if it already exists.
#
# Announcements are dispatched as one workflow run per package, so a release of many packages at
# once (such as for Hanami) can reach this point in several runs at once, each about to create the
# same topic. Looking again after a random moment means they don't all create in lockstep.
def existing_topic(title)
  find_topics(title).first || begin
    sleep rand * CREATE_JITTER_SECONDS
    find_topics(title).first
  end
end

# Gives up our newly created topic in favour of an older duplicate, if a concurrent run created one.
# Returns the URL of the post announcing the release.
#
# Every run treats the oldest topic as the keeper, so runs never delete each other's topics. Each
# run removes only the duplicate it created itself.
def settle_duplicate_topics(title, topic_id, body)
  sleep DUPLICATE_SETTLE_SECONDS
  keeper = find_topics(title).first

  return topic_url(topic_id) if keeper.nil? || keeper["id"] == topic_id

  puts "Duplicate topic created concurrently: keeping #{keeper["id"]}, removing #{topic_id}"
  delete_topic(topic_id)
  reply_to_topic(keeper["id"], body)
end

# Announces the release in the topic for its series, creating that topic if it doesn't exist yet.
# Returns the URL of the post.
def post_announcement(title, body)
  topic = existing_topic(title)
  return reply_to_topic(topic["id"], body) if topic

  created = create_topic(title, body)
  return settle_duplicate_topics(title, created["topic_id"], body) if created

  # Discourse rejected our title as already used, so another run created the topic in the moment
  # between our last look and our own attempt.
  topic = find_topics(title).first or
    abort "ERROR: Topic #{title.inspect} was rejected as a duplicate but could not be found"
  reply_to_topic(topic["id"], body)
end

def print_dry_run(title, body)
  puts "DRY RUN: nothing will be posted"
  puts "Topic: #{title}"

  if FORUM_CONFIGURED
    existing = find_topics(title).first
    puts(existing ? "Action: reply to #{topic_url(existing["id"])}" : "Action: create topic")
  else
    puts "Action: unknown (set FORUM_URL, FORUM_CATEGORY_ID and FORUM_API_KEY to check for an existing topic)"
  end

  puts "Post:"
  puts body
end

# Prepare forum post
title = topic_title(package_name, version)

heading = "## #{package_name} #{version}"
heading += " (#{label})" unless label.empty?

body = "#{heading}\n\n"
body += release_body.strip
body += "\n\n---\n\n"
body += "[View release on GitHub](#{release_url})"

if DRY_RUN
  print_dry_run(title, body)
  exit 0
end

# Post to Discourse, in the topic for this release series
puts "Posted to Discourse: #{post_announcement(title, body)}"
