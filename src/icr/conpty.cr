# ConPTY adapter (Windows): the platform twin of pty.cr's openpty.
# The live backend needs a real TTY: the interpreter's line editor
# (lib/reply) reads key events from stdin and crashes on a 0x0 window
# size, so we always pass a size to CreatePseudoConsole. The child is
# spawned with PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE via CreateProcessW
# (the stdlib Process cannot attach a pseudoconsole).
#
# The pipes come from the stdlib's IO.pipe: the read end we keep is
# overlapped, so #read honors read_timeout through the IOCP event loop
# (plain blocking ReadFile has no timeout support on Windows); the
# conhost ends stay synchronous.

{% if flag?(:windows) %}
  @[Link("kernel32")]
  lib Icr::LibConPty
    struct Coord
      x : Int16
      y : Int16
    end

    # pseudoconsole API (Windows 10 1809+)
    fun CreatePseudoConsole(size : Coord, hInput : LibC::HANDLE, hOutput : LibC::HANDLE,
                            dwFlags : UInt32, phPC : LibC::HANDLE*) : Int32
    fun ClosePseudoConsole(hPC : LibC::HANDLE) : Void

    fun InitializeProcThreadAttributeList(lpAttributeList : Void*, dwAttributeCount : UInt32,
                                          dwFlags : UInt32, lpSize : UInt64*) : Int32
    # NOTE: for PSEUDOCONSOLE the lpValue parameter receives the HPCON
    # handle ITSELF (by value), not a pointer to it — passing &handle
    # makes the child die at startup with STATUS_DLL_INIT_FAILED.
    # cbSize/lpSize are SIZE_T (UInt64): a 32-bit stack slot corrupts
    # the Win64 ABI.
    fun UpdateProcThreadAttribute(lpAttributeList : Void*, dwFlags : UInt32,
                                  attribute : UInt64, lpValue : Void*, cbSize : UInt64,
                                  lpPreviousValue : Void*, lpReturnSize : UInt64*) : Int32
    fun DeleteProcThreadAttributeList(lpAttributeList : Void*) : Void

    # not bound in Crystal's LibC
    fun SetStdHandle(nStdHandle : LibC::DWORD, hHandle : LibC::HANDLE) : Int32

    struct StartupInfoExW
      startup_info : LibC::STARTUPINFOW
      attribute_list : Void*
    end

    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016_u64
    EXTENDED_STARTUPINFO_PRESENT        = 0x00080000_u32
    WAIT_TIMEOUT                        = 0x00000102_u32
  end

  # A process attached to a ConPTY pseudoconsole. The interface mirrors
  # the Unix Icr::Pty in pty.cr so Icr::LiveSession is platform-neutral.
  class Icr::Pty
    class Error < Exception; end

    ROWS = 50
    COLS = 500

    def self.open(bin : String, args : Enumerable(String), cwd : String?,
                  env : Hash(String, String)) : self
      # input pipe: we write / conhost reads — both ends synchronous.
      # output pipe: conhost writes / we read — our end overlapped so
      # read timeouts work (see file comment).
      con_in, our_in = IO.pipe(read_blocking: true, write_blocking: true)
      our_out, con_out = IO.pipe(read_blocking: false, write_blocking: true)

      size = LibConPty::Coord.new(x: COLS.to_i16!, y: ROWS.to_i16!)
      hr = LibConPty.CreatePseudoConsole(size, LibC::HANDLE.new(con_in.fd),
        LibC::HANDLE.new(con_out.fd), 0_u32, out hpc)
      if hr != 0
        con_in.close; our_in.close; our_out.close; con_out.close
        raise Error.new("CreatePseudoConsole failed (0x#{hr.to_s(16)})")
      end

      # attribute list carrying the pseudoconsole handle; the buffer
      # must outlive CreateProcessW (kept alive by attr_buf)
      attr_size = uninitialized UInt64 # SIZE_T (pointer-sized)
      LibConPty.InitializeProcThreadAttributeList(Pointer(Void).null, 1, 0,
        pointerof(attr_size))
      attr_buf = Bytes.new(attr_size)
      attr_list = attr_buf.to_unsafe.as(Void*)
      if LibConPty.InitializeProcThreadAttributeList(attr_list, 1, 0, pointerof(attr_size)) == 0 ||
         LibConPty.UpdateProcThreadAttribute(attr_list, 0,
             LibConPty::PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
             hpc.as(Void*), sizeof(LibC::HANDLE),
             Pointer(Void).null, Pointer(UInt64).null) == 0
        raise Error.new("InitializeProcThreadAttributeList failed")
      end

      si = LibConPty::StartupInfoExW.new
      si.startup_info.cb = sizeof(LibConPty::StartupInfoExW)
      si.attribute_list = attr_list

      cmdline = String.build do |io|
        io << quote_cmd(bin)
        args.each { |a| io << ' ' << quote_cmd(a) }
      end.to_utf16 # CreateProcessW may modify the buffer in place
      env_block = String.build do |io|
        env.each { |k, v| io << k << '=' << v << '\0' }
      end.to_utf16
      cwd_w = cwd.try &.to_utf16

      pi = LibC::PROCESS_INFORMATION.new
      # Without STARTF_USESTDHANDLES a console child gets duplicates of the
      # PARENT's standard handles whenever those are not console handles
      # (pipes/files) — overriding the pseudoconsole wiring. Detach our
      # stdio for the duration of the spawn so the child receives the
      # pseudoconsole's console handles; restore right after.
      saved_in = LibC.GetStdHandle(LibC::STD_INPUT_HANDLE)
      saved_out = LibC.GetStdHandle(LibC::STD_OUTPUT_HANDLE)
      saved_err = LibC.GetStdHandle(LibC::STD_ERROR_HANDLE)
      LibConPty.SetStdHandle(LibC::STD_INPUT_HANDLE, Pointer(Void).null)
      LibConPty.SetStdHandle(LibC::STD_OUTPUT_HANDLE, Pointer(Void).null)
      LibConPty.SetStdHandle(LibC::STD_ERROR_HANDLE, Pointer(Void).null)
      ok = LibC.CreateProcessW(
        Pointer(UInt16).null, cmdline.to_unsafe,
        Pointer(LibC::SECURITY_ATTRIBUTES).null, Pointer(LibC::SECURITY_ATTRIBUTES).null,
        0, # bInheritHandles must be FALSE with ConPTY
        LibConPty::EXTENDED_STARTUPINFO_PRESENT | LibC::CREATE_UNICODE_ENVIRONMENT,
        env_block.to_unsafe.as(Void*),
        cwd_w ? cwd_w.to_unsafe : Pointer(UInt16).null,
        pointerof(si).as(LibC::STARTUPINFOW*), pointerof(pi))
      LibConPty.SetStdHandle(LibC::STD_INPUT_HANDLE, saved_in)
      LibConPty.SetStdHandle(LibC::STD_OUTPUT_HANDLE, saved_out)
      LibConPty.SetStdHandle(LibC::STD_ERROR_HANDLE, saved_err)

      LibConPty.DeleteProcThreadAttributeList(attr_list)
      # conhost owns its pipe ends now; our copies would only keep the
      # pipes alive after the client exits
      con_in.close
      con_out.close

      if ok == 0
        err = WinError.value
        LibConPty.ClosePseudoConsole(hpc)
        LibC.CloseHandle(pi.hProcess) unless pi.hProcess.address == 0
        our_in.close; our_out.close
        raise Error.new("CreateProcessW failed (#{err.message})")
      end

      LibC.CloseHandle(pi.hThread)
      new(our_in, our_out, hpc, pi.hProcess)
    end

    def initialize(@input : IO::FileDescriptor, @output : IO::FileDescriptor,
                   @hpc : LibC::HANDLE, @hprocess : LibC::HANDLE)
      @closed = false
    end

    def read(buf : Bytes) : Int32
      @output.read(buf)
    end

    def write(slice : Bytes) : Nil
      @input.write(slice)
      @input.flush
    end

    def read_timeout=(value : Time::Span?) : Nil
      @output.read_timeout = value
    end

    def exists? : Bool
      !@closed && LibC.WaitForSingleObject(@hprocess, 0) == LibConPty::WAIT_TIMEOUT
    end

    # *graceful* is ignored: Win32 has no SIGTERM — always a hard kill.
    def terminate(graceful : Bool = true) : Nil
      LibC.TerminateProcess(@hprocess, 1) unless @closed
    end

    def wait : Nil
      LibC.WaitForSingleObject(@hprocess, 0xFFFFFFFF_u32)
    end

    def close : Nil
      return if @closed
      @closed = true
      @input.close rescue nil # EOF: conhost tears the console down
      @output.close rescue nil
      # safe and quick once the client has exited (LiveSession.close
      # ensures that before calling us)
      LibConPty.ClosePseudoConsole(@hpc)
      LibC.CloseHandle(@hprocess)
    end

    private def self.quote_cmd(s : String) : String
      (s.includes?(' ') || s.empty?) ? %("#{s}") : s
    end
  end
{% end %}
