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
# Run `bundle exec rspec` in `.github/scripts` to test this script.

require "json"

# Maximum seconds to wait before creating a topic, so concurrent runs don't create in lockstep.
CREATE_JITTER_SECONDS = 5
# Seconds to wait before checking whether a concurrent run created a duplicate of our new topic.
DUPLICATE_SETTLE_SECONDS = 5

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

# The post announcing a single release, as Discourse markdown. The heading identifies the release
# within a topic that collects the whole series.
def announcement_body(package_name:, version:, label:, notes:, release_url:)
  heading = "## #{package_name} #{version}"
  heading += " (#{label})" unless label.to_s.empty?

  "#{heading}\n\n#{notes.strip}\n\n---\n\n[View release on GitHub](#{release_url})"
end

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

def linkify_release_notes(notes, owner, repo_name)
  notes.gsub(CLOSING_PARENS_REGEXP) do
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
end

# Discourse API client, scoped to the category we announce into.
class Forum
  # How many pages of the category's topic listing to search for an existing topic.
  MAX_TOPIC_PAGES = 20

  def initialize(url:, category_id:, api_key:)
    @url = url
    @category_id = category_id
    @api_key = api_key
  end

  def topic_url(topic_id)
    "#{url}/t/#{topic_id}"
  end

  # Returns topics in our category with exactly this title, oldest first.
  #
  # This walks the category's topic listing rather than using /search.json, because Discourse's
  # search index updates asynchronously and we need to see topics created moments ago (see the race
  # handling in #post_announcement).
  def find_topics(title)
    topics = []
    page = 0

    while page < MAX_TOPIC_PAGES
      response = http.get("#{url}/latest.json?category=#{category_id}&no_subcategories=true&page=#{page}")
      abort_on_error response, "listing topics in category #{category_id}"

      topic_list = response.parse["topic_list"]
      topics.concat(topic_list["topics"].to_a.select { _1["title"] == title })

      break unless topic_list["more_topics_url"]
      page += 1
    end

    # Sorted by id so callers can take the oldest, which is what makes concurrent runs converge on
    # the same topic.
    topics.sort_by { _1["id"] }
  end

  # Returns the new topic, or nil if Discourse rejected the title as already used.
  def create_topic(title, body)
    response = http.post("#{url}/posts.json", json: {title:, raw: body, category: category_id.to_i})

    return nil if !response.status.success? && duplicate_title?(response)

    abort_on_error response, "creating topic #{title.inspect}"
    response.parse
  end

  # Returns the URL of the new post.
  def reply_to_topic(topic_id, body)
    response = http.post("#{url}/posts.json", json: {topic_id:, raw: body})
    abort_on_error response, "replying to topic #{topic_id}"

    "#{topic_url(topic_id)}/#{response.parse["post_number"]}"
  end

  def delete_topic(topic_id)
    response = http.delete("#{url}/t/#{topic_id}.json")

    unless response.status.success?
      # Not fatal: the announcement still goes into the topic we're keeping, leaving an empty
      # duplicate behind for manual cleanup. Warn on stderr so this never reaches the workflow's
      # capture of the post URL from stdout.
      warn "WARNING: Could not delete duplicate topic #{topic_id} (HTTP #{response.code}): #{response.body}"
    end

    response.status.success?
  end

  private

  attr_reader :url, :category_id, :api_key

  def http
    HTTP.headers("Content-Type" => "application/json", "Api-Key" => api_key)
  end

  def duplicate_title?(response)
    errors = begin
      JSON.parse(response.body.to_s)["errors"]
    rescue JSON::ParserError
      nil
    end

    errors.to_a.any? { _1.to_s.match?(/title has already been used/i) }
  end

  def abort_on_error(response, action)
    return if response.status.success?

    puts "ERROR: Discourse API returned HTTP #{response.code} when #{action}"
    puts "Response: #{response.body}"
    exit 1
  end
end

# Returns the topic for this release series, if it already exists.
#
# Announcements are dispatched as one workflow run per package, so a release of many packages at
# once (such as for Hanami) can reach this point in several runs at once, each about to create the
# same topic. Looking again after a random moment means they don't all create in lockstep.
def existing_topic(forum, title, jitter_seconds)
  forum.find_topics(title).first || begin
    sleep rand * jitter_seconds
    forum.find_topics(title).first
  end
end

# Gives up our newly created topic in favour of an older duplicate, if a concurrent run created one.
# Returns the URL of the post announcing the release.
#
# Every run treats the oldest topic as the keeper, so runs never delete each other's topics: each
# removes only the duplicate it created itself.
def settle_duplicate_topics(forum, title, topic_id, body, settle_seconds)
  sleep settle_seconds
  keeper = forum.find_topics(title).first

  return forum.topic_url(topic_id) if keeper.nil? || keeper["id"] == topic_id

  puts "Duplicate topic created concurrently: keeping #{keeper["id"]}, removing #{topic_id}"
  forum.delete_topic(topic_id)
  forum.reply_to_topic(keeper["id"], body)
end

# Announces the release in the topic for its series, creating that topic if it doesn't exist yet.
# Returns the URL of the post.
def post_announcement(
  forum, title, body,
  jitter_seconds: CREATE_JITTER_SECONDS,
  settle_seconds: DUPLICATE_SETTLE_SECONDS
)
  topic = existing_topic(forum, title, jitter_seconds)
  return forum.reply_to_topic(topic["id"], body) if topic

  created = forum.create_topic(title, body)
  return settle_duplicate_topics(forum, title, created["topic_id"], body, settle_seconds) if created

  # Discourse rejected our title as already used, so another run created the topic in the moment
  # between our last look and our own attempt.
  topic = forum.find_topics(title).first or
    abort "ERROR: Topic #{title.inspect} was rejected as a duplicate but could not be found"
  forum.reply_to_topic(topic["id"], body)
end

# Runs the script only when invoked directly.
#
# This allows specs to load and test specific behavior without running the whole script.
if __FILE__ == $PROGRAM_NAME
  require "bundler/inline"

  gemfile do
    source "https://gem.coop"
    gem "http"
  end

  # Prepare input
  package_name = ARGV[0] or abort "ERROR: Package name required"
  repo = ARGV[1] or abort "ERROR: Repository required (format: owner/repo)"
  tag = ARGV[2] or abort "ERROR: Release tag required"
  label = ARGV[3].to_s.strip # Optional; empty when omitted

  owner, repo_name = repo.split("/")
  abort "ERROR: Invalid repository format. Expected owner/repo" unless owner && repo_name

  forum_url = ENV["FORUM_URL"]
  forum_category_id = ENV["FORUM_CATEGORY_ID"]
  forum_api_key = ENV["FORUM_API_KEY"]
  github_token = ENV["GITHUB_TOKEN"] # Optional

  # Unset secrets and env vars arrive as empty strings, so treat blank as missing.
  abort "ERROR: FORUM_URL env var required" if forum_url.to_s.strip.empty?
  abort "ERROR: FORUM_CATEGORY_ID env var required" if forum_category_id.to_s.strip.empty?
  abort "ERROR: FORUM_API_KEY secret required" if forum_api_key.to_s.strip.empty?

  forum = Forum.new(url: forum_url, category_id: forum_category_id, api_key: forum_api_key)

  # Fetch release from GitHub
  github_response = HTTP
    .tap { _1.auth("Bearer #{github_token}") if github_token }
    .get("https://api.github.com/repos/#{owner}/#{repo_name}/releases/tags/#{tag}")

  unless github_response.status.success?
    puts "ERROR: GitHub API returned HTTP #{github_response.code}"
    puts "Response: #{github_response.body}"
    exit 1
  end

  release = github_response.parse
  version = release["tag_name"].sub(/^v/, "")

  # Prepare forum post
  title = topic_title(package_name, version)
  body = announcement_body(
    package_name:,
    version:,
    label:,
    notes: linkify_release_notes(release["body"].to_s, owner, repo_name),
    release_url: release["html_url"]
  )

  # Post to Discourse, in the topic for this release series
  puts "Posted to Discourse: #{post_announcement(forum, title, body)}"
end
