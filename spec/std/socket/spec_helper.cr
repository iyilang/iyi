require "spec"
require "socket"

CLOSE_ON_EXEC_AVAILABLE = {{ !flag?(:win32) }}

module SocketSpecHelper
  class_getter?(supports_ipv6 : Bool) { detect_supports_ipv6? }

  private def self.detect_supports_ipv6? : Bool
    TCPServer.open("::1", 0) { return true }
    false
  rescue Socket::Error
    false
  end

  # Whether *error* reports the address as already in use.
  def self.address_in_use?(error : Socket::BindError) : Bool
    case os_error = error.os_error
    when Errno    then os_error == Errno::EADDRINUSE
    when WinError then os_error == WinError::WSAEADDRINUSE
    else               false
    end
  end

  # Whether no IPv6 socket holds *port*, checked with an IPv6-only wildcard
  # bind. Only an address-in-use failure answers false; any other error raises.
  def self.ipv6_port_free?(port : Int32) : Bool
    socket = TCPServer.new(:inet6)
    begin
      socket.ipv6_only = true
      socket.bind(Socket::IPAddress::UNSPECIFIED6, port)
      true
    rescue ex : Socket::BindError
      raise ex unless address_in_use?(ex)
      false
    ensure
      socket.close
    end
  end
end

def pending_ipv6(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if SocketSpecHelper.supports_ipv6?
    it(description, file: file, line: line, end_line: end_line, &block)
  else
    pending(description, file: file, line: line, end_line: end_line)
  end
end

def each_ip_family(&block : Socket::Family, String, String ->)
  describe "using IPv4" do
    block.call Socket::Family::INET, "127.0.0.1", "0.0.0.0"
  end

  if SocketSpecHelper.supports_ipv6?
    describe "using IPv6" do
      block.call Socket::Family::INET6, "::1", "::"
    end
  else
    pending "using IPv6"
  end
end

# Returns a port no TCP socket of either family holds. A port-0 IPv4 bind skips
# ports held by IPv4 and dual stack sockets but not IPv6-only ones (and on macOS
# a port-0 IPv6 bind skips nothing IPv4 holds), so each IPv4 candidate stays
# bound while `SocketSpecHelper.ipv6_port_free?` checks the IPv6 side. A
# candidate an IPv6 socket holds is released for the next one; there are no
# more candidates than TCP ports.
def unused_local_tcp_port
  check_ipv6 = SocketSpecHelper.supports_ipv6?

  UInt16::MAX.times do
    TCPServer.open(Socket::IPAddress::UNSPECIFIED, 0) do |server|
      port = server.local_address.port
      return port if !check_ipv6 || SocketSpecHelper.ipv6_port_free?(port)
    end
  end

  raise Socket::Error.new("No TCP port is free for both IPv4 and IPv6 after #{UInt16::MAX} candidates")
end

def unused_local_udp_port
  socket = UDPSocket.new
  begin
    socket.bind(Socket::IPAddress::UNSPECIFIED, 0)
    socket.local_address.port
  ensure
    socket.close
  end
end
