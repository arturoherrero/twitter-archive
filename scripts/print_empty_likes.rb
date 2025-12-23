#!/usr/bin/env ruby

require "json"

content = File.read("data/likes.js")
json_str = content.sub(/\Awindow\.LIKES\s*=\s*/, "")
likes = JSON.parse(json_str)

empty_likes = likes.select { |l| l["text"].nil? }

puts "Found #{empty_likes.length} likes without text:\n\n"

empty_likes.each do |l|
  puts l["url"]
end
