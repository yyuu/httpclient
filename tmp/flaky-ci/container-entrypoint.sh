#!/usr/bin/env bash
set -euo pipefail
export CI=1 HTTPCLIENT_PROJECT_ROOT=/subject
mkdir -p /tmp/httpclient-replay
cd /tmp/httpclient-replay
export BUNDLE_GEMFILE="$PWD/Gemfile"
printf '%s\n' 'eval_gemfile "/subject/Gemfile"' > "$BUNDLE_GEMFILE"
cp /snapshot.lock "$BUNDLE_GEMFILE.lock"
bundler=$(ruby -e 'puts File.read(ARGV[0]).split("BUNDLED WITH").last.strip' /snapshot.lock)
export BUNDLER_VERSION="$bundler"
if ! gem list --local --installed bundler --version "$bundler" >/dev/null; then
  gem install bundler --version "$bundler" --no-document
fi
ruby -e 'p = ARGV[0]; File.write(p, File.read(p).sub(/^  remote: \.$/, "  remote: /subject"))' "$BUNDLE_GEMFILE.lock"
bundle "_$bundler"_ config set mirror.http://rubygems.org https://rubygems.org
# Permit the host platform without changing any gem versions from the snapshot.
bundle "_$bundler"_ lock --add-platform "$(ruby -e 'puts Gem::Platform.local')"
ruby -e '
  specs = lambda { |p| File.read(p).scan(/^    ([\w-]+) \(([^)]+)\)/).sort }
  abort "gem versions changed while adding platform" unless specs.call(ARGV[0]) == specs.call(ARGV[1])
' /snapshot.lock "$BUNDLE_GEMFILE.lock"
bundle "_$bundler"_ install --frozen
cd /subject
exec bundle "_$bundler"_ exec ruby -w \
  --enable-frozen-string-literal --debug-frozen-string-literal \
  -Ilib /harness/loaded-repeat.rb
