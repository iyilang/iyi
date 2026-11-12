require "../spec_helper"
require "./spec_helper"

private def section_bounds_file(&block)
  path = File.tempname("iyimod-section-bounds", ".iyimod")
  begin
    yield path
  ensure
    File.delete(path) if File.exists?(path)
  end
end

private def write_section_bounds_header(file : File, count : UInt32)
  file.write(Iyi::IyiMod::MAGIC)
  file.write_bytes(Iyi::IyiMod::FORMAT_VERSION, Iyi::IyiMod::FORMAT)
  file.write_bytes(count, Iyi::IyiMod::FORMAT)
end

describe "iyimod section bounds" do
  it "rejects an oversized section table before allocating it" do
    section_bounds_file do |path|
      File.open(path, "wb") { |file| write_section_bounds_header(file, UInt32::MAX) }
      expect_raises(Iyi::IyiMod::Error, /ends inside the section table/) { Iyi::IyiMod.read(path) }
      expect_raises(Iyi::IyiMod::Error, /ends inside the section table/) { Iyi::IyiMod.read_summary(path) }
      Iyi::IyiMod.read_spawns(path).should be_nil
    end
  end

  it "rejects a declared section larger than the remaining file" do
    section_bounds_file do |path|
      File.open(path, "wb") do |file|
        write_section_bounds_header(file, 1_u32)
        file.write_bytes(Iyi::IyiMod::Section::Header.value, Iyi::IyiMod::FORMAT)
        file.write_bytes(0_u16, Iyi::IyiMod::FORMAT)
        file.write_bytes(1_073_741_824_u32, Iyi::IyiMod::FORMAT)
        file.write_bytes(0_u64, Iyi::IyiMod::FORMAT)
      end
      expect_raises(Iyi::IyiMod::Error, /ends inside a section/) { Iyi::IyiMod.read(path) }
      expect_raises(Iyi::IyiMod::Error, /ends inside a section/) { Iyi::IyiMod.read_summary(path) }
      Iyi::IyiMod.read_spawns(path).should be_nil
    end
  end
end
