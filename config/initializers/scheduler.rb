require 'rufus-scheduler'
require 'stackprof'

# メモリ使用量の履歴を保存する配列（600エントリー分）
$memory_usages = []

scheduler = Rufus::Scheduler.singleton

def backup_postgresql
  # Ensure the backup directory exists
  backup_dir = Rails.root.join('db', 'backup')
  FileUtils.mkdir_p(backup_dir) unless Dir.exist?(backup_dir)

  # database.ymlの内容を読み込み
  db_config = Rails.configuration.database_configuration[Rails.env]

  backup_file = backup_dir.join("backup_#{Time.now.strftime('%Y%m%d%H%M%S')}.sql")
  database_name = db_config["database"]
  username = db_config["username"]
  password = db_config["password"]
  host = db_config["host"]

  # バックアップコマンドの実行
# バックアップコマンドの実行
# config/initializers/scheduler.rb

# バックアップコマンドの実行
Open3.popen3("pg_dump", "-U", username, "-h", host, "-F", "c", "-b", "-v", "-f", backup_file.to_s, database_name) do |stdin, stdout, stderr, wait_thr|
  unless wait_thr.value.success?
    error_message = "Backup failed: #{backup_file} with error: #{stderr.read}"
    Rails.logger.error error_message
    return { success: false, error: error_message }
  end
end


  # バックアップコマンドの成功を確認
  if $?.success? && File.exist?(backup_file) && File.size?(backup_file) > 0
    file_size = File.size(backup_file)
    Rails.logger.info "Backup created successfully: #{backup_file}"
    return { success: true, file: backup_file, size: file_size }
  else
    error_message = "Backup failed: #{backup_file}"
    Rails.logger.error error_message
    return { success: false, error: error_message }
  end
end

# 10秒ごとにメモリの使用量を取得
scheduler.every '60s' do
  memory_usage = `ps -o rss= -p #{Process.pid}`.to_i / 1024  # MB単位
  $memory_usages << memory_usage
  $memory_usages.shift if $memory_usages.length > 600  # 過去1時間（600エントリー）のデータのみ保持
end

# 60分ごとにメモリの使用量の統計とstackprofの結果を計算してメールを送信
scheduler.every '360m' do
  current_memory = $memory_usages.last
  max_memory = $memory_usages.max
  min_memory = $memory_usages.min
  avg_memory = $memory_usages.sum.to_f / $memory_usages.length

  # stackprofの実行と結果の取得
  # mode: :object
  StackProf.run(mode: :object, out: 'tmp/stackprof_object.dump') do
    User.all.load        # データベースから全ユーザーを取得
    Product.all.load     # データベースから全商品を取得
    Touan.all.load       # データベースから全てのTouanを取得
  end
  stackprof_object_results = `stackprof tmp/stackprof_object.dump --text`

  # mode: :cpu
  StackProf.run(mode: :cpu, out: 'tmp/stackprof_cpu.dump') do
    User.all.load        # データベースから全ユーザーを取得
    Product.all.load     # データベースから全商品を取得
    Touan.all.load       # データベースから全てのTouanを取得
  end
  stackprof_cpu_results = `stackprof tmp/stackprof_cpu.dump --text`

  # 結果の結合（メール送信のため）
  stackprof_results = "Object Mode Results:\n#{stackprof_object_results}\n\nCPU Mode Results:\n#{stackprof_cpu_results}"

  # バックアップの試み
  backup_result = backup_postgresql

  # バックアップの成功/失敗に応じてメールの内容を変更
  if backup_result[:success]
    backup_message = "バックアップに成功しました。ファイルサイズ: #{backup_result[:size]} bytes"
  else
    backup_message = backup_result[:error] + "。エラーの詳細を確認してください。"
  end

  # キャッシュカウントの取得
cache_counts = {
  'Product' => Rails.cache.read("products_all")&.count || 0,
  'Touan' => User.all.sum { |user| (Rails.cache.read("touans_#{user.id}")&.count) || 0 },
  # 他のモデルも同様に追加
}

  # メール送信
  begin
    MemoryUsageMailer.send_memory_usage_with_success_message(
      'yasuhiro-suzuki@mitsui-s.com',
      current_memory,
      max_memory,
      min_memory,
      avg_memory,
      stackprof_results,
      backup_message,
      cache_counts  # 追加した引数
    ).deliver_now

    Rails.logger.info "メールが正常に送信されました"
  rescue => e
    Rails.logger.error "メールの送信に失敗しました: #{e.message}"
  end
end
