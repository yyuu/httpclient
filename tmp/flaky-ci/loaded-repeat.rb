# Independent CPU competitors, with cleanup even when repeat.rb exits on failure.
# They share the container's CPU quota but do not change the timeout or server.
workers = Integer(ENV.fetch('LOAD_WORKERS', '0'))
abort 'LOAD_WORKERS must be between 0 and 16' unless (0..16).include?(workers)
pids = []
stats = ['/sys/fs/cgroup/cpu.max', '/sys/fs/cgroup/cpu.stat',
         '/sys/fs/cgroup/memory.events']
snapshot = lambda do |label|
  stats.each do |path|
    puts "#{label} #{path}: #{File.read(path).strip}" if File.readable?(path)
  end
end
$stdout.sync = true
puts "load_workers=#{workers} uname=#{`uname -a`.strip}"
snapshot.call('before')
begin
  workers.times do
    pids << fork do
      # Ruby arithmetic consumes CPU without allocating an unbounded data set.
      value = 0
      loop { value = (value + 1) % 1_000_003 }
    end
  end
  load File.join(__dir__, 'repeat.rb')
ensure
  pids.each do |pid|
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
    end
  end
  pids.each { |pid| Process.wait(pid) }
  snapshot.call('after')
end
