# frozen_string_literal: true

require "test_helper"

class EmcpVersionTest < ActiveSupport::TestCase
  test "reads commit and vX.Y.Z tag from VERSION" do
    path = Rails.root.join("tmp/version-test-#{Process.pid}")
    File.write(path, "commit=abc1234\ntag=v1.2.3\n")

    assert_equal({ commit: "abc1234", tag: "v1.2.3" }, Emcp.read_version_file(path))
  ensure
    FileUtils.rm_f(path)
  end

  test "ignores missing or blank VERSION values" do
    path = Rails.root.join("tmp/version-test-blank-#{Process.pid}")
    File.write(path, "commit=\ntag=\n")

    assert_equal({ commit: nil, tag: nil }, Emcp.read_version_file(path))
    assert_equal({ commit: nil, tag: nil }, Emcp.read_version_file(path.to_s + ".missing"))
  ensure
    FileUtils.rm_f(path)
  end
end
