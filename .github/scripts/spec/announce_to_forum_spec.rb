# frozen_string_literal: true

require_relative "../announce-to-forum"

RSpec.describe "announce-to-forum" do
  # A stand-in for Discourse. Records what was posted and deleted, and lets a spec simulate a
  # concurrent run by injecting a topic partway through #create_topic.
  class FakeForum
    attr_reader :topics, :replies, :deleted_topic_ids

    # reject_duplicate_titles mirrors Discourse's `allow_duplicate_topic_titles` site setting: when
    # true, creating a topic whose title already exists is refused.
    def initialize(topics: [], reject_duplicate_titles: false)
      @topics = topics
      @reject_duplicate_titles = reject_duplicate_titles
      @replies = []
      @deleted_topic_ids = []
      @next_topic_id = 1
    end

    def add_topic(id:, title:)
      @topics << {"id" => id, "title" => title}
    end

    # Runs inside #create_topic, after the caller has already looked for an existing topic.
    def during_create(&block)
      @during_create = block
    end

    def topic_url(topic_id)
      "https://forum.test/t/#{topic_id}"
    end

    def find_topics(title)
      @topics.select { _1["title"] == title }.sort_by { _1["id"] }
    end

    def create_topic(title, body)
      @during_create&.call(self)
      return nil if @reject_duplicate_titles && find_topics(title).any?

      id = (@next_topic_id += 1)
      add_topic(id:, title:)
      {"topic_id" => id, "post_number" => 1, "body" => body}
    end

    def reply_to_topic(topic_id, body)
      @replies << {topic_id:, body:}
      "#{topic_url(topic_id)}/#{@replies.size + 1}"
    end

    def delete_topic(topic_id)
      @deleted_topic_ids << topic_id
      @topics.reject! { _1["id"] == topic_id }
      true
    end
  end

  describe "#topic_title" do
    it "gives every Hanami gem the topic for its Hanami series" do
      expect(topic_title("hanami", "3.0.1")).to eq "Hanami 3.0 released"
      expect(topic_title("hanami-utils", "3.0.1")).to eq "Hanami 3.0 released"
      expect(topic_title("hanami-assets", "3.0.0")).to eq "Hanami 3.0 released"
    end

    it "keeps separate Hanami series apart" do
      expect(topic_title("hanami-cli", "2.3.5")).to eq "Hanami 2.3 released"
      expect(topic_title("hanami-cli", "3.0.0")).to eq "Hanami 3.0 released"
    end

    it "gives other packages their own series topic" do
      expect(topic_title("dry-types", "1.9.1")).to eq "dry-types 1.9 released"
      expect(topic_title("dry-monads", "1.10.0")).to eq "dry-monads 1.10 released"
    end

    it "does not treat packages merely starting with 'hanami' as Hanami gems" do
      expect(topic_title("hanamified", "1.0.0")).to eq "hanamified 1.0 released"
    end

    it "sends prereleases to a preview topic, in both gem and npm version spellings" do
      expect(topic_title("hanami", "3.0.0.rc1")).to eq "Hanami 3.0 (preview) released"
      expect(topic_title("hanami-assets", "3.0.0-rc.1")).to eq "Hanami 3.0 (preview) released"
      expect(topic_title("dry-types", "1.9.0.beta1")).to eq "dry-types 1.9 (preview) released"
    end

    it "aborts on a version it can't place in a series" do
      expect { topic_title("hanami", "nonsense") }.to raise_error(SystemExit)
    end
  end

  describe "#announcement_body" do
    def body(**overrides)
      announcement_body(
        package_name: "hanami-utils",
        version: "3.0.1",
        label: "",
        notes: "### Changed\n\n- Something changed.",
        release_url: "https://github.com/hanami/hanami-utils/releases/tag/v3.0.1",
        **overrides,
      )
    end

    it "heads the post with the specific release, so it's identifiable within a series topic" do
      expect(body).to start_with "## hanami-utils 3.0.1\n\n### Changed"
    end

    it "marks a labelled release in the heading" do
      expect(body(package_name: "hanami-assets", label: "npm")).to start_with "## hanami-assets 3.0.1 (npm)\n"
    end

    it "closes with a link to the GitHub release" do
      expect(body).to end_with "\n\n---\n\n[View release on GitHub](https://github.com/hanami/hanami-utils/releases/tag/v3.0.1)"
    end

    it "strips surrounding whitespace from the release notes" do
      expect(body(notes: "\n\nSomething changed.\n\n")).to include "\n\nSomething changed.\n\n---\n"
    end
  end

  describe "linkify_release_notes" do
    def linkify(notes)
      linkify_release_notes(notes, "hanami", "hanami-utils")
    end

    it "links usernames, pull requests and commits in a trailing parenthetical" do
      expect(linkify("- Fixed a thing (@timriley in #419)")).to eq(
        "- Fixed a thing ([@timriley](https://github.com/timriley) in " \
        "[#419](https://github.com/hanami/hanami-utils/pull/419))"
      )
    end

    it "shortens commit SHAs to seven characters" do
      expect(linkify("- Fixed a thing (1234567890abcdef)")).to eq(
        "- Fixed a thing ([`1234567`](https://github.com/hanami/hanami-utils/commit/1234567890abcdef))"
      )
    end

    it "links within continuation lines of a bullet" do
      expect(linkify("  more detail (@timriley)")).to eq(
        "  more detail ([@timriley](https://github.com/timriley))"
      )
    end

    it "leaves parentheses that aren't at the end of a line alone" do
      expect(linkify("- Fixed a thing (@timriley) and another thing")).to eq(
        "- Fixed a thing (@timriley) and another thing"
      )
    end

    it "leaves lines that aren't bullets or continuations alone" do
      expect(linkify("Thanks to everyone (@timriley)")).to eq "Thanks to everyone (@timriley)"
    end

    it "leaves the rest of the notes untouched" do
      notes = "### Changed\n\n- Allow BigDecimal 3 or 4. (@sandbergja in #419)\n\n[1.0.0]: https://example.com"

      expect(linkify(notes)).to eq(
        "### Changed\n\n- Allow BigDecimal 3 or 4. ([@sandbergja](https://github.com/sandbergja) in " \
        "[#419](https://github.com/hanami/hanami-utils/pull/419))\n\n[1.0.0]: https://example.com"
      )
    end
  end

  describe "#post_announcement" do
    let(:title) { "Hanami 3.0 released" }
    let(:body) { "## hanami-utils 3.0.1\n\nNotes." }

    def announce(forum)
      # No jitter or settle delay, so the specs don't sleep.
      post_announcement(forum, title, body, jitter_seconds: 0, settle_seconds: 0)
    end

    it "replies to the series topic when it already exists" do
      forum = FakeForum.new(topics: [{"id" => 10, "title" => title}])

      url = announce(forum)

      expect(forum.replies).to eq [{topic_id: 10, body:}]
      expect(forum.topics.size).to eq 1
      expect(url).to start_with "https://forum.test/t/10/"
    end

    it "ignores topics for other series" do
      forum = FakeForum.new(topics: [{"id" => 10, "title" => "Hanami 2.3 released"}])

      announce(forum)

      expect(forum.replies).to be_empty
      expect(forum.topics.map { _1["title"] }).to contain_exactly("Hanami 2.3 released", title)
    end

    it "creates the series topic when it doesn't exist yet" do
      forum = FakeForum.new

      url = announce(forum)

      expect(forum.topics).to eq [{"id" => 2, "title" => title}]
      expect(forum.replies).to be_empty
      expect(url).to eq "https://forum.test/t/2"
    end

    describe "when a concurrent run creates the same topic" do
      it "replies to the other run's topic when Discourse rejects our duplicate title" do
        forum = FakeForum.new(reject_duplicate_titles: true)
        forum.during_create { _1.add_topic(id: 7, title:) }

        url = announce(forum)

        expect(forum.replies).to eq [{topic_id: 7, body:}]
        expect(forum.topics).to eq [{"id" => 7, "title" => title}]
        expect(url).to start_with "https://forum.test/t/7/"
      end

      it "gives up its own newer duplicate and replies to the older topic" do
        forum = FakeForum.new
        forum.during_create { _1.add_topic(id: 1, title:) }

        url = announce(forum)

        expect(forum.deleted_topic_ids).to eq [2]
        expect(forum.topics).to eq [{"id" => 1, "title" => title}]
        expect(forum.replies).to eq [{topic_id: 1, body:}]
        expect(url).to start_with "https://forum.test/t/1/"
      end

      it "keeps its own topic when it is the older of the duplicates" do
        forum = FakeForum.new
        forum.during_create { _1.add_topic(id: 99, title:) }

        url = announce(forum)

        expect(forum.deleted_topic_ids).to be_empty
        expect(forum.replies).to be_empty
        expect(url).to eq "https://forum.test/t/2"
      end
    end
  end
end
