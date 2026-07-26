class EnableTrigramExtensions < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"
    enable_extension "unaccent"
  end
end
