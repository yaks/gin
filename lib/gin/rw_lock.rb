##
# Read-Write lock pair for accessing data that is mostly read-bound.
# Reading is done without locking until a write operation is started.
#
#   lock = Gin::RWLock.new
#   lock.write_sync{ write_to_the_object }
#   value = lock.read_sync{ read_from_the_object }
#
# The RWLock is built to work primarily in Thread-pool type environments and its
# effectiveness is much less for Thread-spawn models.
#
# RWLock also shows increased performance in GIL-less Ruby implementations such
# as Rubinius 2.x.
#
# Using write_sync from inside a read_sync block is safe, but the inverse isn't:
#
#   lock = Gin::RWLock.new
#
#   # This is OK.
#   lock.read_sync do
#     get_value || lock.write_sync{ update_value }
#   end
#
#   # This is NOT OK and will raise a ThreadError.
#   # It's also not necessary because read sync-ing is inferred
#   # during write syncs.
#   lock.write_sync do
#     update_value
#     lock.read_sync{ get_value }
#   end

class Gin::RWLock

  class WriteTimeout < StandardError; end

  TIMEOUT_MSG = "Took too long to lock all config mutexes. \
Try increasing the value of Config#write_timeout."

  # The amount of time to wait for writer threads to get all the read locks.
  attr_accessor :write_timeout


  def initialize write_timeout=nil
    @wmutex        = Mutex.new
    @write_timeout = write_timeout || 0.05
    @mutex_id      = :"rwlock_#{self.object_id}"
  end


  def write_sync
    lock_mutexes = []
    relock_curr  = false

    write_mutex.lock

    curr_mutex = Thread.current[@mutex_id]

    # Protect against same-thread deadlocks
    if curr_mutex && curr_mutex.locked?
      relock_curr = curr_mutex.unlock rescue false
    end

    start = Time.now

    Thread.list.each do |t|
      mutex = t[@mutex_id]
      next if !mutex || !relock_curr && t == Thread.current
      until mutex.try_lock
        raise WriteTimeout, TIMEOUT_MSG if Time.now - start > @write_timeout
      end
      lock_mutexes << mutex
    end

    yield
  ensure
    lock_mutexes.each(&:unlock)
    curr_mutex.try_lock if relock_curr
    write_mutex.unlock
  end


  def read_sync
    read_mutex.synchronize{ yield }
  end


  private


  def write_mutex
    @wmutex
  end


  def read_mutex
    return Thread.current[@mutex_id] if Thread.current[@mutex_id]
    @wmutex.synchronize{ Thread.current[@mutex_id] = Mutex.new }
  end
end