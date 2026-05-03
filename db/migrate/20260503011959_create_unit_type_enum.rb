class CreateUnitTypeEnum < ActiveRecord::Migration[8.1]
  def up
    execute "CREATE TYPE unit_type AS ENUM ('unit', 'weight', 'volume')"
  end

  def down
    execute "DROP TYPE unit_type"
  end
end
