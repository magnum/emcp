# frozen_string_literal: true

require "fileutils"

class SplitMcpServersIntoTypesAndInstances < ActiveRecord::Migration[8.1]
  def up
    create_table :mcp_server_types do |t|
      t.string :code, null: false
      t.string :class_name, null: false
      t.string :name, null: false
      t.text :description, default: "", null: false
      t.string :version, default: "0.1.0", null: false
      t.boolean :allow_write, default: false, null: false
      t.boolean :oauth_token_retrieval, default: false, null: false
      t.integer :token_refresh_in_minutes
      t.integer :service_token_refresh_in_minutes
      t.timestamps
    end
    add_index :mcp_server_types, :code, unique: true
    add_index :mcp_server_types, :class_name, unique: true

    execute <<~SQL.squish
      INSERT INTO mcp_server_types (
        code, class_name, name, description, version, allow_write,
        oauth_token_retrieval, token_refresh_in_minutes,
        service_token_refresh_in_minutes, created_at, updated_at
      )
      SELECT
        code, type, name, description, version, allow_write,
        oauth_token_retrieval, token_refresh_in_minutes,
        service_token_refresh_in_minutes, created_at, updated_at
      FROM mcp_servers
    SQL

    add_reference :mcp_servers, :mcp_server_type, foreign_key: true
    add_reference :mcp_servers, :user, foreign_key: true

    execute <<~SQL.squish
      UPDATE mcp_servers
      SET mcp_server_type_id = (
        SELECT mcp_server_types.id
        FROM mcp_server_types
        WHERE mcp_server_types.code = mcp_servers.code
      )
    SQL

    owner_id = first_owner_id
    if owner_id
      execute("UPDATE mcp_servers SET user_id = #{owner_id.to_i} WHERE user_id IS NULL")
    end

    copy_legacy_data_dirs

    if connection.select_value("SELECT COUNT(*) FROM mcp_servers WHERE user_id IS NULL").to_i.zero?
      change_column_null :mcp_servers, :user_id, false
    end
    change_column_null :mcp_servers, :mcp_server_type_id, false

    remove_index :mcp_servers, name: "index_mcp_servers_on_code"
    remove_column :mcp_servers, :code
    remove_column :mcp_servers, :version
    remove_column :mcp_servers, :oauth_token_retrieval
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def first_owner_id
    connection.select_value(<<~SQL.squish) || connection.select_value("SELECT id FROM users ORDER BY id LIMIT 1")
      SELECT users.id
      FROM users
      INNER JOIN users_roles ON users_roles.user_id = users.id
      INNER JOIN roles ON roles.id = users_roles.role_id
      WHERE roles.name = 'admin'
      ORDER BY users.id
      LIMIT 1
    SQL
  end

  def copy_legacy_data_dirs
    connection.select_all("SELECT id, code FROM mcp_servers").each do |row|
      source = Rails.root.join("storage", "mcp", row["code"].to_s)
      next unless source.directory?

      destination = Rails.root.join("storage", "mcp", "instances", row["id"].to_s)
      next if destination.exist?

      FileUtils.mkdir_p(destination.dirname)
      FileUtils.cp_r(source, destination)
    end
  end
end
