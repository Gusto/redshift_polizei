##
# all methods have an optional filter parameter +table+,
# which takes a hash containing:
# - :schema_name
# - :table_name
# all methods return a hash of this style:
# - full_table_name_1: <value>, ...
#
class TableUtils
  ##
  # returns the full table name based on schema and table name
  #
  def self.build_full_table_name(schema_name, table_name)
    "#{schema_name}.#{table_name}"
  end

  ##
  # return all table names in the connected database
  #
  def self.get_all_table_names(connection, table={})
    tmp = execute_grouped_by_table(connection, 'tables/exists', table)
    tmp.hmap do |full_table_name, columns|
      columns[0] # we don't need an array with one element
    end
  end

  ##
  # returns the columns with all their properties in the defined order of
  # the given table (except dist & sort keys)
  # to retrieve sort & dist keys use `get_sort_and_dist_keys`
  #
  def self.get_columns(connection, table={})
    tmp = execute_grouped_by_table(connection, 'tables/columns', table)
    tmp.hmap do |full_table_name, columns|
      columns.sort_by { |col| col['position'].to_i } # missing pg type conversion -.-
    end
  end

  ##
  # retrieves the primary and foreign key as well as the unique constraints
  # for the given table.
  # does not support compound keys!
  #
  def self.get_table_constraints(connection, table={})
    execute_grouped_by_table(connection, 'tables/constraints', table)
  end

  ##
  # returns the distribution & sorting styles of tables
  #
  def self.get_sort_and_dist_styles(connection, table={})
    tmp = execute_grouped_by_table(connection, 'tables/dist_sort_style', table)
    tmp.hmap do |full_table_name, dist_style_array|
      dist_style_array[0] # there is only one dist style, so don't return an array
    end
  end

  ##
  # returns the sort and dist keys of tables
  #
  def self.get_sort_and_dist_keys(connection, table={})
    tmp = execute_grouped_by_table(connection, 'tables/sort_dist_keys', table)
    tmp.hmap do |full_table_name, result|
      sort_keys = result.sort_by do |r|
        r['attsortkeyord'].to_i
      end.select do |r|
        (r['attsortkeyord'].to_i > 0)
      end.map do |r|
        r['attname']
      end
      dist_key = nil
      tmp = result.select { |r| (r['attisdistkey'] == 't') }
      dist_key = tmp[0]['attname'] if not tmp.empty?
      { 'sort_keys' => sort_keys, 'dist_key' => dist_key }
    end
  end

  ##
  # returns a boolean for each table indicating
  # whether it has at least one column with an
  # encoding
  #
  def self.has_column_encodings(connection, table={})
    tmp = execute_grouped_by_table(connection, 'tables/has_encoding', table)
    tmp.hmap do |full_table_name, encoding_columns|
      !encoding_columns.empty?
    end
  end

  ##
  # returns statistics (size, skew, slice population) for each table
  #
  def self.get_size_skew_populated(connection, table={})
    execute_grouped_by_table(connection, 'tables/size_skew_populated', table)
  end

  ##
  # returns info on all the tables that are dependent on the specified one
  #
  def self.get_dependent_tables(connection, table={})
    filters = { 'constraint_type' => 'f' }
    filters['ref_namespace'] = table[:schema_name] if table.has_key?(:schema_name)
    filters['ref_tablename'] = table[:table_name] if table.has_key?(:table_name)
    SQL.execute_grouped(connection, 'tables/constraints', filters: filters) do |r|
      unless r.has_key?('schema_name') && r.has_key?('table_name') && r.has_key?('constraint_name') && r.has_key?('contraint_columnname') && r.has_key?('ref_columnname')
        fail 'Missing constraint info'
      end
      self.build_full_table_name(r['ref_namespace'], r['ref_tablename'])
    end
  end

  def self.get_table_comments(connection, table={})
    tmp = execute_grouped_by_table(connection, 'tables/comments.sql', table)
    tmp.hmap do |full_table_name, comments_array|
      comments_array[0]
    end
  end

  ##
  # groups SQL results in a hash by 'schema_name'
  # and 'table_name' from the retrieved rows
  #
  def self.execute_grouped_by_table(*args)
    tmp = args.pop || {}
    filters = {}
    filters['trim(n.nspname)'] = tmp[:schema_name] if tmp.has_key?(:schema_name)
    filters['trim(c.relname)'] = tmp[:table_name] if tmp.has_key?(:table_name)
    SQL.execute_grouped(*args, filters: filters) do |result|
      unless result.has_key?('schema_name') && result.has_key?('table_name')
        fail 'Missing schema_name or table_name'
      end
      self.build_full_table_name(result['schema_name'], result['table_name'])
    end
  end
end
