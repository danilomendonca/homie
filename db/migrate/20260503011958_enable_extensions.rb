class EnableExtensions < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"
    enable_extension "pgcrypto"
  end
end
