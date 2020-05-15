class App
  hash_routes.on 'prefix1' do |r|
    set_view_subdir 'prefix1'
  end
end
