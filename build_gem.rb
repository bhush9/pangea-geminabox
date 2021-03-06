# frozen_string_literal: true
#
# Copyright © 2017 Harald Sitter <sitter@kde.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of
# the License or (at your option) version 3 or any later version
# accepted by the membership of KDE e.V. (or its successor approved
# by the membership of KDE e.V.), which shall act as a proxy
# defined in Section 14 of version 3 of the license.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'fileutils'
require 'rubygems/package'
require 'tmpdir'
require 'yaml'

# Mangles a gemspec file so we can build it into something sane.
class GemSpecMangler
  attr_reader :path
  attr_reader :new_path

  def self.find_file(dir)
    gemspecs = Dir.glob("#{dir}/*.gemspec")
    raise "too many gemspecs #{gemspecs}" if gemspecs.size > 1
    raise "couldnt find gemspec file in #{Dir.pwd}" if gemspecs.empty?
    gemspecs[0]
  end

  def initialize(path = self.class.find_file)
    @path = File.absolute_path(path)
    @new_path = "#{path}.new"
  end

  def mangle!
    injected = false
    File.open(new_path, 'w') do |out|
      File.open(path).each_line do |line|
        if line.strip.start_with?('#') || injected
          out.write(line)
          next
        end
        # The line is the first line that is not a comment whilest not having
        # injected our magic.
        injected = true
        # We mangle the spec data generated later in the gemspec file by
        # disabling and all push restrictions and setting an ever increasing
        # version
        out.write(File.read("#{__dir__}/mangler.template"))
        out.write(line)
      end
    end
  end
end

dir = File.expand_path(ARGV[0])

FileUtils.rm_rf('pangeapkg')
spec = GemSpecMangler.new(GemSpecMangler.find_file(dir))
spec.mangle!
# This would be much nicer if we simply called gem build in the pwd where
# we want the gem to be. BUT, shitty gemspecs that do not resolve paths
# to their absolute variant will then fail to find assets.
system('gem', 'build', spec.new_path, '-V', chdir: dir) || raise

# The version of our gem is retained across builds and only changes to new
# commits. To prevent us from uploading an already existing version we'll
# attempt to fetch our gem. If we already uploaded the thing we'll have 1
# gem and be able to exit.
gem_files = Dir.glob("#{dir}/*.gem")
raise "Too many gems! #{gemfiles}" unless gem_files.size == 1
gem_file = gem_files.fetch(0)
gem_spec = Gem::Package.new(gem_file).spec

# Validate our spec against the one in the box (if it has one.)
Dir.mktmpdir do |tmpdir|
  system('gem', 'fetch',
         '--prerelease',
         '--clear-sources',
         '--source', 'https://gem.cache.pangea.pub',
         gem_spec.name,
         chdir: tmpdir)
  gems = Dir.glob("#{tmpdir}/*.gem")
  # Should't have more than 1 obviously.
  raise "Fetched too many gems #{gems}" if gems.size > 1

  if !gems.empty? && File.basename(gems[0]) == File.basename(gem_file)
    puts "Gem already exists in the box #{gem_files}"
    exit
  elsif !gems.empty?
    # Our _new_ version should be greater than the fetched one.
    other_spec = Gem::Package.new(gems.fetch(0)).spec
    if gem_spec.version < other_spec.version
      raise "Our new version is older than the one in the box!!!\n" \
            "#{gem_spec} vs. #{other_spec}"
    end
  end
end

# .gem/credentials controls API_KEY used here.
system('gem', 'push', gem_file,
       '--host', 'https://gem.cache.pangea.pub') || raise
