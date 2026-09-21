{% skip_file if flag?(:bits32) %}

require "spec"
require "compiler/iyi/formatter"
require "compiler/iyi/command/format"
require "../../../support/tempfile"

private class BuggyFormatCommand < Iyi::Command::FormatCommand
  def format(filename, source)
    raise "format command test"
  end
end

describe Iyi::Command::FormatCommand do
  it "formats stdin" do
    stdin = IO::Memory.new "if true\n1\nend"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(0)
    stdout.to_s.should eq("if true\n  1\nend\n")
    stderr.to_s.should be_empty
  end

  it "formats stdin (formatted)" do
    stdin = IO::Memory.new "if true\n  1\nend\n"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(0)
    stdout.to_s.should eq("if true\n  1\nend\n")
    stderr.to_s.should be_empty
  end

  it "formats stdin (syntax error)" do
    stdin = IO::Memory.new "if"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    # iyi: `STDIN` ends in neither extension, and the language a file is in
    # comes off its name everywhere in the compiler, so a pipe was read by
    # the other language's rules. It is `STDIN.iyi` now, which says which
    # rules read it, and `--stdin-filename` replaces it.
    stderr.to_s.should contain("syntax error in 'STDIN.iyi:1:3': unexpected token: EOF")
  end

  it "formats stdin (invalid byte sequence error)" do
    stdin = IO::Memory.new "\xfe\xff"
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = Iyi::Command::FormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    stderr.to_s.should contain("file 'STDIN.iyi' is not a valid iyi source file: Unexpected byte 0xfe at position 0, malformed UTF-8")
  end

  it "formats stdin (bug)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = BuggyFormatCommand.new(["-"], stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    stderr.to_s.should contain("there's a bug formatting 'STDIN.iyi', to show more information, please run:")
    # iyi: the advice names the binary that was run, whatever it was
    # called - it used to say `crystal tool format`, a command the reader
    # may not have.
    stderr.to_s.should contain("#{File.basename(PROGRAM_NAME)} tool format --show-backtrace -")
  end

  it "formats stdin (bug + show-backtrace)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    format_command = BuggyFormatCommand.new(["-"], show_backtrace: true, stdin: stdin, stdout: stdout, stderr: stderr)
    format_command.run
    format_command.status_code.should eq(1)
    stdout.to_s.should be_empty
    stderr.to_s.should contain("format command test")
    stderr.to_s.should contain("couldn't format 'STDIN.iyi', please report a bug including the contents of it: https://github.com/iyilang/iyi/issues")
  end

  it "reads stdin as the language --stdin-filename names" do
    # `x = y()!` is a propagation in iyi and a syntax error in Crystal, so
    # the flag is observable rather than decoration: the same bytes format
    # under the default and are refused under a `.cr` name, which is also
    # the name the error carries.
    source = "x = y()!\n"

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    iyi = Iyi::Command::FormatCommand.new(["-"],
      stdin: IO::Memory.new(source), stdout: stdout, stderr: stderr)
    iyi.run
    iyi.status_code.should eq(0)
    stdout.to_s.should eq(source)
    stderr.to_s.should be_empty

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    as_cr = Iyi::Command::FormatCommand.new(["-"],
      stdin: IO::Memory.new(source), stdout: stdout, stderr: stderr,
      stdin_filename: "buffer.cr")
    as_cr.run
    as_cr.status_code.should eq(1)
    stderr.to_s.should contain("syntax error in 'buffer.cr:1:8'")
  end

  it "formats files" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.cr", "if true\n1\nend"
      File.write "not_format.cr", "if true\n  1\nend\n"

      format_command = Iyi::Command::FormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should contain("Format #{Path[".", "format.cr"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "not_format.cr"]}")
      stderr.to_s.should be_empty

      File.read("format.cr").should eq("if true\n  1\nend\n")
    end
  end

  it "formats files (dir)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      Dir.mkdir "dir"
      File.write "format.cr", "if true\n1\nend"
      File.write "not_format.cr", "if true\n  1\nend\n"
      File.write File.join("dir", "format.cr"), "if true\n1\nend"
      File.write File.join("dir", "not_format.cr"), "if true\n  1\nend\n"

      format_command = Iyi::Command::FormatCommand.new(["dir"], color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should contain("Format #{Path[".", "dir", "format.cr"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "dir", "not_format.cr"]}")
      stderr.to_s.should be_empty

      {stdout, stderr}.each &.clear

      format_command = Iyi::Command::FormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should contain("Format #{Path[".", "format.cr"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "not_format.cr"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "dir", "format.cr"]}")
      stdout.to_s.should_not contain("Format #{Path[".", "dir", "not_format.cr"]}")
      stderr.to_s.should be_empty

      File.read("format.cr").should eq("if true\n  1\nend\n")
      File.read(File.join("dir", "format.cr")).should eq("if true\n  1\nend\n")
    end
  end

  it "formats files (error)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.cr", "if true\n1\nend"
      File.write "syntax_error.cr", "if"
      File.write "invalid_byte_sequence_error.cr", "\xfe\xff"

      format_command = Iyi::Command::FormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stdout.to_s.should contain("Format #{Path[".", "format.cr"]}")
      stderr.to_s.should contain("syntax error in '#{Path[".", "syntax_error.cr"]}:1:3': unexpected token: EOF")
      stderr.to_s.should contain("file '#{Path[".", "invalid_byte_sequence_error.cr"]}' is not a valid Crystal source file: Unexpected byte 0xfe at position 0, malformed UTF-8")

      File.read("format.cr").should eq("if true\n  1\nend\n")
    end
  end

  it "formats files (bug)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "empty.cr", ""

      format_command = BuggyFormatCommand.new([] of String, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stderr.to_s.should contain("there's a bug formatting '#{Path[".", "empty.cr"]}', to show more information, please run:")
      stderr.to_s.should contain("#{File.basename(PROGRAM_NAME)} tool format --show-backtrace '#{Path[".", "empty.cr"]}'")
    end
  end

  it "formats files (bug + show-stacktrace)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "empty.cr", ""

      format_command = BuggyFormatCommand.new([] of String, show_backtrace: true, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stderr.to_s.should contain("format command test")
      stderr.to_s.should contain("couldn't format '#{Path[".", "empty.cr"]}', please report a bug including the contents of it: https://github.com/iyilang/iyi/issues")
    end
  end

  it "checks files format" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.cr", "if true\n1\nend"
      File.write "not_format.cr", "if true\n  1\nend\n"
      File.write "syntax_error.cr", "if"
      File.write "invalid_byte_sequence_error.cr", "\xfe\xff"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stdout.to_s.should be_empty
      stderr.to_s.should_not contain("not_format.cr")
      stderr.to_s.should contain("formatting '#{Path[".", "format.cr"]}' produced changes")
      stderr.to_s.should contain("syntax error in '#{Path[".", "syntax_error.cr"]}:1:3': unexpected token: EOF")
      stderr.to_s.should contain("file '#{Path[".", "invalid_byte_sequence_error.cr"]}' is not a valid Crystal source file: Unexpected byte 0xfe at position 0, malformed UTF-8")
    end
  end

  it "checks files format (ok)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format1.cr", "if true\n  1\nend\n"
      File.write "format2.cr", "if true\n  2\nend\n"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should be_empty
      stderr.to_s.should be_empty
    end
  end

  it "checks files format (excludes)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.cr", "if true\n1\nend"
      File.write "not_format.cr", "if true\n  1\nend\n"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, excludes: ["format.cr"], color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(0)
      stdout.to_s.should be_empty
      stderr.to_s.should be_empty
    end
  end

  it "checks files format (excludes + includes)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      File.write "format.cr", "if true\n1\nend"
      File.write "not_format.cr", "if true\n  1\nend\n"

      format_command = Iyi::Command::FormatCommand.new([] of String, check: true, excludes: ["format.cr"], includes: ["format.cr"], color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stdout.to_s.should be_empty
      stderr.to_s.should contain("formatting '#{Path[".", "format.cr"]}' produced changes")
    end
  end

  # iyi: a path that is not there is the one case where the check is
  # certainly not being performed, and it used to print that and exit 0 —
  # so `iyi tool format --check "$FILE" || exit 1` passed on a typo.
  it "checks a path that is not there (fails)" do
    stdin = IO::Memory.new ""
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    with_tempdir do
      format_command = Iyi::Command::FormatCommand.new(["nosuch.iyi"], check: true, color: false, stdin: stdin, stdout: stdout, stderr: stderr)
      format_command.run
      format_command.status_code.should eq(1)
      stdout.to_s.should be_empty
      stderr.to_s.should contain("file or directory does not exist: #{Path[".", "nosuch.iyi"]}")
    end
  end
end
