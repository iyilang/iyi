require "./spec_helper"

# A program kept deep in a directory tree builds. The compiler's cache
# directory was named for the source's whole path, and past a certain
# depth that name was one no file system takes: on Windows a 222-character
# path - which Windows opens - put the cache directory at 262 characters,
# past MAX_PATH, and the build said "The system cannot find the path
# specified"; anywhere, a path past 255 characters made a name longer than
# a name may be. Deep enough here to be past both, and short enough on
# Windows for the source itself to open.
describe "a program at a deep path" do
  it "builds and runs" do
    target = {{ flag?(:win32) ? 240 : 300 }}
    root = File.tempname("deep")
    dir = root
    while File.join(dir, "proje_klasoru", "deep.iyi").size < target
      dir = File.join(dir, "proje_klasoru")
    end
    Dir.mkdir_p(dir)
    source = File.join(dir, "deep.iyi")
    File.write(source, %(module main\n\nputs "deep"\n))
    output = File.join(root, "deep#{EXE_SUFFIX}")

    Process.capture_result(iyi, "build", source, "-o", output).should be_success
    Process.capture_result(output).output.should eq "deep\n"
  ensure
    FileUtils.rm_rf(root) if root
  end
end
