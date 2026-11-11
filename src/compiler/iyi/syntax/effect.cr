module Iyi
  enum EffectClass
    Observed
    Output
    NotReusable
    Internal
    TaintOnly
  end

  enum EffectKind : UInt8
    # observed (1..8)
    FileRead   = 1_u8
    FileStat   = 2_u8
    FileExists = 3_u8
    DirList    = 4_u8
    EnvGet     = 5_u8
    EnvAll     = 6_u8
    Cwd        = 7_u8
    Host       = 8_u8

    # output (16..18)
    Stdio     = 16_u8
    Exit      = 17_u8
    FileWrite = 18_u8

    # not reusable (32..39)
    Clock         = 32_u8
    Entropy       = 33_u8
    Timer         = 34_u8
    Network       = 35_u8
    Process       = 36_u8
    Signal        = 37_u8
    RuntimeTiming = 38_u8
    CodeLocation  = 39_u8
    DirStream     = 40_u8
    HostState     = 41_u8

    # taint only (48)
    SharedWrite = 48_u8

    # internal (64..72)
    Memory             = 64_u8
    Collector          = 65_u8
    Threads            = 66_u8
    Scheduler          = 67_u8
    SelfImage          = 68_u8
    Console            = 69_u8
    PanicBacktrace     = 70_u8
    TempName           = 71_u8
    ObservationChannel = 72_u8
    Primitive          = 73_u8

    def effect_class : EffectClass
      case self
      when FileRead, FileStat, FileExists, DirList, EnvGet, EnvAll, Cwd, Host
        EffectClass::Observed
      when Stdio, Exit, FileWrite
        EffectClass::Output
      when Clock, Entropy, Timer, Network, Process, Signal, RuntimeTiming, CodeLocation, DirStream, HostState
        EffectClass::NotReusable
      when SharedWrite
        EffectClass::TaintOnly
      when Memory, Collector, Threads, Scheduler, SelfImage, Console, PanicBacktrace, TempName, ObservationChannel, Primitive
        EffectClass::Internal
      else
        raise "unknown effect kind #{self}"
      end
    end

    def symbol_name : String
      case self
      when FileRead           then "file_read"
      when FileStat           then "file_stat"
      when FileExists         then "file_exists"
      when DirList            then "dir_list"
      when EnvGet             then "env_get"
      when EnvAll             then "env_all"
      when Cwd                then "cwd"
      when Host               then "host"
      when Stdio              then "stdio"
      when Exit               then "exit"
      when FileWrite          then "file_write"
      when Clock              then "clock"
      when Entropy            then "entropy"
      when Timer              then "timer"
      when Network            then "network"
      when Process            then "process"
      when Signal             then "signal"
      when RuntimeTiming      then "runtime_timing"
      when CodeLocation       then "code_location"
      when DirStream          then "dir_stream"
      when HostState          then "host_state"
      when SharedWrite        then "shared_write"
      when Memory             then "memory"
      when Collector          then "collector"
      when Threads            then "threads"
      when Scheduler          then "scheduler"
      when SelfImage          then "self_image"
      when Console            then "console"
      when PanicBacktrace     then "panic_backtrace"
      when TempName           then "temp_name"
      when ObservationChannel then "observation_channel"
      when Primitive          then "primitive"
      else
        raise "unknown effect kind: #{self}"
      end
    end

    def self.from_symbol?(name : String) : EffectKind?
      case name
      when "file_read"           then FileRead
      when "file_stat"           then FileStat
      when "file_exists"         then FileExists
      when "dir_list"            then DirList
      when "env_get"             then EnvGet
      when "env_all"             then EnvAll
      when "cwd"                 then Cwd
      when "host"                then Host
      when "stdio"               then Stdio
      when "exit"                then Exit
      when "file_write"          then FileWrite
      when "clock"               then Clock
      when "entropy"             then Entropy
      when "timer"               then Timer
      when "network"             then Network
      when "process"             then Process
      when "signal"              then Signal
      when "runtime_timing"      then RuntimeTiming
      when "code_location"       then CodeLocation
      when "dir_stream"          then DirStream
      when "host_state"          then HostState
      when "memory"              then Memory
      when "collector"           then Collector
      when "threads"             then Threads
      when "scheduler"           then Scheduler
      when "self_image"          then SelfImage
      when "console"             then Console
      when "panic_backtrace"     then PanicBacktrace
      when "temp_name"           then TempName
      when "observation_channel" then ObservationChannel
      when "primitive"           then Primitive
      else
        nil
      end
    end
  end

  enum FileWriteOp : UInt8
    Create  = 1_u8
    Delete  = 2_u8
    Rename  = 3_u8
    Mkdir   = 4_u8
    Link    = 5_u8
    Symlink = 6_u8
    Touch   = 7_u8
    Chmod   = 8_u8

    def symbol_name : String
      case self
      when Create  then "create"
      when Delete  then "delete"
      when Rename  then "rename"
      when Mkdir   then "mkdir"
      when Link    then "link"
      when Symlink then "symlink"
      when Touch   then "touch"
      when Chmod   then "chmod"
      else
        raise "unknown op: #{self}"
      end
    end

    def self.from_symbol?(name : String) : FileWriteOp?
      case name
      when "create"  then Create
      when "delete"  then Delete
      when "rename"  then Rename
      when "mkdir"   then Mkdir
      when "link"    then Link
      when "symlink" then Symlink
      when "touch"   then Touch
      when "chmod"   then Chmod
      else
        nil
      end
    end
  end

  class Effect
    getter kind : EffectKind
    getter op : FileWriteOp?

    def initialize(@kind : EffectKind, @op : FileWriteOp? = nil)
    end

    def effect_class : EffectClass
      @kind.effect_class
    end

    def observed? : Bool
      effect_class.observed?
    end

    def output? : Bool
      effect_class.output?
    end

    def not_reusable? : Bool
      effect_class.not_reusable?
    end

    def internal? : Bool
      effect_class.internal?
    end

    def taint_only? : Bool
      effect_class.taint_only?
    end

    def to_s(io : IO) : Nil
      io << "Effect(:" << @kind.symbol_name
      if op = @op
        io << ", :" << op.symbol_name
      end
      io << ")"
    end
  end
end
