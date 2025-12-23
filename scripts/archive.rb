#!/usr/bin/env ruby

require "json"
require "cgi"
require "fileutils"

class TwitterArchiveProcessor
  YOUR_SCREEN_NAME = "ArturoHerrero"
  TWITTER_STATUS_REGEX = %r{https?://(x|twitter)\.com/\w+/status/\d+}

  def initialize
    @tweets_file = "data/tweets.js"
    @likes_file = "data/like.js"
    @source_media_dir = "data/tweets_media"
    @source_profile_dir = "data/profile_media"
  end

  def call
    process_tweets
    process_likes
    cleanup_archive
    organize_files
  end

  private

  def process_tweets
    return unless File.exist?(@tweets_file)

    tweets = parse_twitter_js(@tweets_file)
    processed = tweets.map { |t| process_tweet(t["tweet"]) }

    File.write("tweets.js", "window.TWEETS = #{JSON.pretty_generate(processed)}")

    puts "Tweets: #{processed.length}"
    print_tweet_summary(processed)
  end

  def process_likes
    return unless File.exist?(@likes_file)

    likes = parse_twitter_js(@likes_file)
    processed = likes
      .map { |l| process_like(l["like"]) }
      .compact

    File.write("likes.js", "window.LIKES = #{JSON.pretty_generate(processed)}")

    empty_count = processed.count { |l| l[:text].nil? }
    puts "\nLikes: #{processed.length} (#{empty_count} without text)"
  end

  def parse_twitter_js(file)
    content = File.read(file)
    json_str = content.sub(/\Awindow\.YTD\.\w+\.part0\s*=\s*/, "")
    JSON.parse(json_str)
  end

  # Tweet processing

  def process_tweet(tweet)
    entities = tweet["entities"] || {}
    extended_entities = tweet["extended_entities"] || {}
    urls = entities["urls"] || []
    media = extended_entities["media"] || entities["media"] || []
    mentions = entities["user_mentions"] || []
    hashtags = entities["hashtags"] || []

    {
      id: tweet["id"],
      created_at: tweet["created_at"],
      text: expand_urls(tweet["full_text"], urls, media),
      type: detect_tweet_type(tweet),
      url: build_tweet_url(tweet),
      in_reply_to_status_id: tweet["in_reply_to_status_id"],
      in_reply_to_screen_name: tweet["in_reply_to_screen_name"],
      favorite_count: tweet["favorite_count"].to_i,
      retweet_count: tweet["retweet_count"].to_i,
      media: extract_media(tweet["id"], media),
      quoted_tweet: extract_quoted_tweet(urls),
      mentions: mentions.map { |m| m["screen_name"] }.then { |a| a.empty? ? nil : a },
      hashtags: hashtags.map { |h| h["text"] }.then { |a| a.empty? ? nil : a }
    }.compact
  end

  def detect_tweet_type(tweet)
    full_text = tweet["full_text"] || ""
    reply_to_screen_name = tweet["in_reply_to_screen_name"]

    if full_text.start_with?("RT @")
      "retweet"
    elsif reply_to_screen_name
      reply_to_screen_name == YOUR_SCREEN_NAME ? "thread" : "reply"
    else
      "tweet"
    end
  end

  def expand_urls(text, urls, media)
    return text if text.nil?

    result = CGI.unescapeHTML(text)

    urls.each do |url|
      next unless url["url"]

      if url["expanded_url"]&.match?(TWITTER_STATUS_REGEX)
        result.gsub!(url["url"], "") # Remove quoted tweet URLs
      elsif url["expanded_url"]
        result.gsub!(url["url"], url["expanded_url"])
      end
    end

    media.each do |m|
      result.gsub!(m["url"], "") if m["url"]
    end

    result.strip
  end

  def extract_media(tweet_id, media)
    return nil if media.empty?

    media.map do |m|
      media_type = m["type"]

      if media_type == "video" || media_type == "animated_gif"
        video_url = m.dig("video_info", "variants")
          &.select { |v| v["content_type"] == "video/mp4" }
          &.max_by { |v| v["bitrate"].to_i }
          &.dig("url")
          &.split("?")&.first

        filename = video_url ? "#{tweet_id}-#{File.basename(video_url)}" : nil
      else
        filename = extract_media_filename(tweet_id, m["media_url_https"])
      end

      source_path = File.join(@source_media_dir, filename) if filename

      {
        type: media_type,
        url: m["media_url_https"],
        local_file: filename,
        exists: filename && File.exist?(source_path)
      }
    end
  end

  def extract_media_filename(tweet_id, media_url)
    return nil unless media_url

    url_filename = File.basename(media_url)
    "#{tweet_id}-#{url_filename}"
  end

  def extract_quoted_tweet(urls)
    quoted_url = urls.find { |u| u["expanded_url"]&.match?(TWITTER_STATUS_REGEX) }
    return nil unless quoted_url

    expanded = quoted_url["expanded_url"]
    if (match = expanded.match(%r{https?://(x|twitter)\.com/(\w+)/status/(\d+)}))
      {
        url: expanded.gsub("twitter.com", "x.com"),
        username: match[2],
        status_id: match[3]
      }
    end
  end

  def build_tweet_url(tweet)
    full_text = tweet["full_text"] || ""

    if full_text.start_with?("RT @")
      if (match = full_text.match(/^RT @(\w+):/))
        original_author = match[1]

        extended_entities = tweet["extended_entities"] || {}
        media = extended_entities["media"] || []
        source_status_id = media.first&.dig("source_status_id")

        if source_status_id
          return "https://x.com/#{original_author}/status/#{source_status_id}"
        end
      end
    end

    "https://x.com/#{YOUR_SCREEN_NAME}/status/#{tweet["id"]}"
  end

  def print_tweet_summary(tweets)
    types = tweets.group_by { |t| t[:type] }
    types.each { |type, list| puts "  #{type}: #{list.length}" }

    with_media = tweets.count { |t| t[:media] }
    puts "  with media: #{with_media}"
  end

  # Like processing

  def process_like(like)
    text = like["fullText"].to_s.strip
    text = CGI.unescapeHTML(text) unless text.empty?

    {
      text: text.empty? ? nil : text,
      url: like["expandedUrl"]
    }.compact
  end

  def cleanup_archive
    puts "\nCleaning up archive..."

    # Move media folders to temporary location (will reorganize later)
    if Dir.exist?(@source_media_dir)
      FileUtils.mv(@source_media_dir, "tweets_media_tmp")
      puts "  Moved #{@source_media_dir} → tweets_media_tmp"
    end

    if Dir.exist?(@source_profile_dir)
      FileUtils.mv(@source_profile_dir, "profile_media_tmp")
      puts "  Moved #{@source_profile_dir} → profile_media_tmp"
    end

    # Remove unnecessary files and folders
    to_remove = ["assets", "data", "Your archive.html"]
    to_remove.each do |path|
      if File.exist?(path) || Dir.exist?(path)
        FileUtils.rm_rf(path)
        puts "  Removed #{path}"
      end
    end

    puts "Cleanup complete!"
  end

  def organize_files
    puts "\nOrganizing files..."

    # Create data directory
    FileUtils.mkdir_p("data")

    # Move JS files to data/
    FileUtils.mv("tweets.js", "data/tweets.js") if File.exist?("tweets.js")
    FileUtils.mv("likes.js", "data/likes.js") if File.exist?("likes.js")
    puts "  Moved tweets.js, likes.js → data/"

    # Move media folders to data/ with new names
    if Dir.exist?("tweets_media_tmp")
      FileUtils.mv("tweets_media_tmp", "data/media")
      puts "  Moved tweets_media → data/media"
    end

    if Dir.exist?("profile_media_tmp")
      FileUtils.mv("profile_media_tmp", "data/profile")
      puts "  Moved profile_media → data/profile"
    end

    puts "Organization complete!"
  end
end

TwitterArchiveProcessor.new.call
