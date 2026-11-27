{% if flag?(:win32) %}
  require "c/ntdll"
  require "crystal/system/win32/windows_registry"
{% end %}

module Iyi::Stale::WinVersion
  {% if flag?(:win32) %}
    private def self.version : LibNTDLL::RTL_OSVERSIONINFOW
      info = LibNTDLL::RTL_OSVERSIONINFOW.new
      info.size = sizeof(LibNTDLL::RTL_OSVERSIONINFOW).to_u32
      raise "RtlGetVersion failed" unless LibNTDLL.RtlGetVersion(pointerof(info)) == 0
      info
    end

    def self.build : Int32
      version.buildNumber.to_i32
    rescue
      # An unknown version cannot establish that a volume has safe change times.
      0
    end

    def self.kernel : String
      info = version
      # Predefined HKEYs are signed LONGs widened to pointer size on Win64.
      root = Pointer(Void).new(0xffffffff80000002_u64).as(LibC::HKEY)
      path = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion".to_utf16
      name = "UBR".to_utf16
      bytes = Bytes.new(4)
      result = Crystal::System::WindowsRegistry.open?(root, path) do |key|
        Crystal::System::WindowsRegistry.get_raw(key, name, bytes)
      end
      unless result && result[0] == LibC::RegistryRoutineFlags::DWORD && result[1] == 4
        raise "Cannot read Windows kernel UBR"
      end
      ubr = bytes[0].to_u32 | (bytes[1].to_u32 << 8) | (bytes[2].to_u32 << 16) | (bytes[3].to_u32 << 24)
      "#{info.majorVersion}.#{info.minorVersion}.#{info.buildNumber}.#{ubr}"
    end
  {% end %}
end
