#!/usr/bin/env ruby
# copyright @ stanley cai <stanley.w.cai@gmail.com>
#
# impressed by Axel E. Brzostowski iPhone PNG Images Normalizer in Python
# Jeff talked about the PNG formats in more details in his blog
# http://iphonedevelopment.blogspot.com/2008/10/iphone-optimized-pngs.html
#
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

require "zlib"
require "optparse"

class ApplePngNormalizer

  class Error < StandardError; end
  class CorruptPNG < Error; end

  PNG_HEADER = "\x89PNG\r\n\x1a\n"

  Section = Struct.new(:type, :length, :data, :crc, :width, :height)

  def normalize(source_data)
    source_data.force_encoding PNG_HEADER.encoding if source_data.respond_to?(:force_encoding)
    destination_data = source_data[0, PNG_HEADER.length].dup
    raise CorruptPNG unless destination_data == PNG_HEADER
    sections = extract_sections source_data, destination_data.length
    reconstruct_sections destination_data, sections
    destination_data
  end


  # Given a single set of data, will return the normalized png
  # and return the normalized data.
  def self.normalize(data)
    instance = new
    instance.normalize data
  end

  # Given a source file and a destination file, will attempt
  # to save the reverted version of the file from source path
  # at destination path.
  def self.normalize_file(source_path, destination_path)
    raise ArgumentError, "#{source_path} does not exist." unless File.exist?(source_path)
    original = File.open(source_path, 'rb') { |f| f.read }
    normalized = self.normalize File.read(source_path)
    File.open(destination_path, 'wb') do |file|
      file.write normalized
    end if normalized
  end

  # Searches recursively under the given path and normalises any found
  # pngs. This is the default mode and invoked on the command line
  # without a --help argument.
  def self.normalize_under(path)
    Dir[File.join(path, "**/*.png")].each do |png|
      # Skip already normalized pngs.
      next if png =~ /_norm\.png$/
      # and process any that aren't.
      normalize_file png, png.gsub(/\.png$/, '_norm.png')
    end
  end

  def self.parse_options!(source = ARGV)
    options[:quiet] = source.include? "-q"
    options[:help]  = source.include? "--help"
    source.reject! { |v| v[0, 1] == "-" }
    options[:input]     = ARGV.shift
    options[:output]    = ARGV.shift
    options[:directory] = (options[:input] && File.directory?(options[:input]))
    options[:help]      = !(options[:directory] || (options[:input] && options[:output]))
  end

  def self.options
    @options ||= {}
  end

  def self.run
    parse_options!
    if options[:help]
      STDERR.puts "Usage: #{$0} [-q] input-file output-file"
      STDERR.puts "or...  #{$0} [-q] input-directory"
      exit 1
    elsif options[:directory]
      normalize_under options[:input]
    else
      normalize_file options[:input], options[:output]
    end
  end

  private

  def extract_sections(source_data, initial_offset)
    pos      = initial_offset
    sections = []

    while pos < source_data.length
      # use "N" instead of "L", using network endian not native endian
      length = source_data[pos, 4].unpack('N')[0]
      type   = source_data[pos + 4, 4]
      data   = source_data[pos + 8, length]
      crc    = source_data[pos + 8 + length, 4].unpack('N')[0]
      pos   += (length + 12)
      
      # Ignore the CgBI chunk
      next if type == "CgBI"
      
      if type == "IHDR"
        width  = data[0, 4].unpack("N")[0]
        height = data[4, 4].unpack("N")[0]
      end

      # When we encounter multiple sequential IDAT sections, concatenate them together.
      if type == 'IDAT' && sections.size > 0 && sections.last.first == 'IDAT'
        # Append to the previous IDAT
        sections.last.length += length
        sections.last.data += data
      else
        sections << Section.new(type, length, data, crc, width, height)
      end

      # Stop once we encounter the IEND section.
      break if type == "IEND"
      
    end

    sections
  end

  def reconstruct_sections(buffer, sections)

    # (type, length, data, crc, width, height)

    sections.each do |section|

      crc    = section.crc
      data   = section.data
      length = section.length

      if section.type == "IDAT"

        width, height = section.width, section.height

        buffer_size = width * height * 4 + height
        data        = decompress section.data[0, buffer_size]

        # duplicate the content of old data at first to avoid creating too many string objects
        chunk_data = data.dup
        pos     = 0

        # Restructure each section to fit inside the data correct
        (0...height).each do |y|
          chunk_data[pos] = data[pos, 1]
          pos += 1
          (0...width).each do |y|
            chunk_data[pos + 0] = data[pos + 2, 1]
            chunk_data[pos + 1] = data[pos + 1, 1]
            chunk_data[pos + 2] = data[pos + 0, 1]
            chunk_data[pos + 3] = data[pos + 3, 1]
            pos += 4
          end
        end

        data   = compress chunk_data
        length = data.length

        # Recalculate the crc.
        crc = Zlib.crc32 section.type
        crc = Zlib.crc32 data, crc
      end

      # Repack the section into the image.
      buffer << [length].pack("N")
      buffer << section.type
      buffer << (data || '')
      buffer << [crc].pack("N")
    end
  end


  def decompress(data)
    # Makes it such that zlib will not check the header before
    # inflating.
    zstream = Zlib::Inflate.new -Zlib::MAX_WBITS
    buf     = zstream.inflate(data)
    zstream.finish
    zstream.close
    buf
  end

  def compress(data)
    Zlib::Deflate.deflate data
  end

end

ApplePngNormalizer.run
