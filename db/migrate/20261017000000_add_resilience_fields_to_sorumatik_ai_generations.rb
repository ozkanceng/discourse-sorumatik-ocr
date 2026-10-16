# frozen_string_literal: true

class AddResilienceFieldsToSorumatikAiGenerations < ActiveRecord::Migration[7.0]
  def change
    add_column :sorumatik_ai_generations, :content_sha256, :string unless column_exists?(:sorumatik_ai_generations, :content_sha256)
    add_column :sorumatik_ai_generations, :execution_id, :string unless column_exists?(:sorumatik_ai_generations, :execution_id)
    add_column :sorumatik_ai_generations, :heartbeat_at, :datetime unless column_exists?(:sorumatik_ai_generations, :heartbeat_at)
    add_column :sorumatik_ai_generations, :provider_completed, :boolean, default: false, null: false unless column_exists?(:sorumatik_ai_generations, :provider_completed)
    add_column :sorumatik_ai_generations, :attempts, :integer, default: 0, null: false unless column_exists?(:sorumatik_ai_generations, :attempts)

    unless index_exists?(:sorumatik_ai_generations, [:state, :heartbeat_at], name: "idx_sorumatik_generations_state_heartbeat")
      add_index :sorumatik_ai_generations, [:state, :heartbeat_at], name: "idx_sorumatik_generations_state_heartbeat"
    end
  end
end
