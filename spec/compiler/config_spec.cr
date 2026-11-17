require "../spec_helper"
require "./spec_helper"

describe Iyi::Config do
  it ".host_target" do
    {% begin %}
      {% host_triple = Iyi.constant("HOST_TRIPLE") || Crystal::DESCRIPTION.lines[-1].gsub(/^Default target: /, "") %}
      Iyi::Config.host_target.should eq Iyi::Codegen::Target.new({{ host_triple }})
    {% end %}
  end
  describe ".macos_link_version" do
    it "computes numeric component-wise minimum" do
      Iyi::Config.macos_link_version("27.0", "27.0.1").should eq "27.0"
      Iyi::Config.macos_link_version("27.1", "27.0.1").should eq "27.0"
      Iyi::Config.macos_link_version("26.5", "27.0.1").should eq "26.5"
      Iyi::Config.macos_link_version(nil, "27.0.1").should eq "27.0"
      Iyi::Config.macos_link_version("27.0", nil).should eq "27.0"
      Iyi::Config.macos_link_version(nil, nil).should be_nil
      Iyi::Config.macos_link_version("27.10", "27.9").should eq "27.9"
      Iyi::Config.macos_link_version("x", nil).should be_nil
    end
  end

  {% if flag?(:linux) %}
    it ".linux_runtime_libc" do
      Iyi::Config.linux_runtime_libc.should eq {{ flag?(:musl) ? "musl" : "gnu" }}
    end
  {% end %}
end
