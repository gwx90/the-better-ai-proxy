require 'yaml'
require 'json'
require 'uri'

root = File.expand_path('..', __dir__)
path = File.join(root, 'templates/routing.yaml')
config = YAML.load_file(path)
def check(value, message)
  raise message unless value
end

groups = config.fetch('proxy-groups')
by_name = groups.to_h { |group| [group.fetch('name'), group] }
builtins = %w[DIRECT REJECT REJECT-DROP PASS]
check(groups.length == by_name.length, 'Duplicate group names')
check(config.fetch('proxy-providers').empty?, 'Template must not contain subscription providers')
check(config.fetch('proxies', []).empty?, 'Template must not contain static nodes')
check(config['mode'] == 'rule', 'Rule mode is required')
check(config.dig('dns', 'enhanced-mode') == 'fake-ip', 'Unexpected DNS mode')
check(by_name.fetch('🧩 机场订阅').fetch('use') == [], 'Template must not bind personal sources')
check(groups.select { |g| g.key?('use') }.map { |g| g['name'] } == ['🧩 机场订阅'], 'Duplicated source binding lists')

groups.each do |group|
  Array(group['proxies']).each do |name|
    check(by_name.key?(name) || builtins.include?(name), "Unknown group reference in #{group['name']}")
  end
end
visited = {}; visiting = {}
walk = lambda do |name|
  return if visited[name] || builtins.include?(name)
  check(!visiting[name], "Group cycle at #{name}")
  visiting[name] = true
  Array(by_name.fetch(name)['proxies']).each { |child| walk.call(child) }
  visiting.delete(name)
  visited[name] = true
end
by_name.each_key { |name| walk.call(name) }

ordinary = by_name.fetch('🎬 YouTube').fetch('proxies')
%w[ChatGPT Claude Gemini].push('🌐 Google').each do |name|
  group = by_name.fetch(name)
  check(group['type'] == 'select' && group['proxies'] == ordinary, 'Service choices must match ordinary groups')
  check(!group.key?('filter') && !group.key?('include-all-providers'), 'Service must not restrict node regions')
  check(ordinary.include?(group['default-selected']), 'Invalid service default')
end
names = groups.map { |g| g['name'] }
check(names[names.index('🌐 Google') + 1, 4] == ['ChatGPT', 'Claude', 'Gemini', '🖥 Microsoft'], 'Unexpected AI service order')

rules = config.fetch('rules')
rules.each do |rule|
  parts = rule.split(',')
  target = parts[0] == 'MATCH' ? parts[1] : parts[2]
  check(by_name.key?(target) || builtins.include?(target), 'Unknown rule target')
  if parts[0] == 'RULE-SET'
    check(config.fetch('rule-providers').key?(parts[1]), 'Unknown rule provider')
  end
end
{'chatgpt.com' => 'ChatGPT', 'openai.com' => 'ChatGPT', 'claude.ai' => 'Claude', 'anthropic.com' => 'Claude', 'robinfrontend-pa.googleapis.com' => 'Gemini'}.each do |domain, target|
  matches = rules.select { |r| r.split(',')[1] == domain }
  check(!matches.empty? && matches.all? { |r| r.split(',')[2] == target }, 'Incorrect AI domain target')
end
check(rules.first(4) == ['DOMAIN,localhost,DIRECT', 'DOMAIN-SUFFIX,localhost,DIRECT', 'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve', 'IP-CIDR6,::1/128,DIRECT,no-resolve'], 'Loopback rules must remain first')
check(rules.index('DOMAIN,robinfrontend-pa.googleapis.com,Gemini') < rules.index('DOMAIN-SUFFIX,googleapis.com,🌐 Google'), 'Gemini rules must precede broad Google rules')

# Simulate independent new subscriptions, without touching the template.
nodes = ['【来源A】USA New Route', '【来源B】🇯🇵Japan New Route', '【来源C】🇸🇬Singapore New Route', '【来源C】剩余流量', '【来源C】🇺🇸BitTorrent专用']
candidates = lambda do |group|
  check(group['include-all-providers'], 'Dynamic group must discover providers')
  nodes.select do |name|
    include_match = !group['filter'] || Regexp.new(group['filter'].sub('(?i)', ''), Regexp::IGNORECASE).match?(name)
    exclude_match = group['exclude-filter'] && Regexp.new(group['exclude-filter'].sub('(?i)', ''), Regexp::IGNORECASE).match?(name)
    include_match && !exclude_match
  end
end
{'🇺🇸 美国地区' => nodes[0], '🇯🇵 日本地区' => nodes[1], '🇸🇬 新加坡地区' => nodes[2]}.each do |name, node|
  check(candidates.call(by_name.fetch(name)).include?(node), 'New source not discovered by region')
end
['⚡ 最低延迟', '🛟 故障转移', '⚖️ 负载均衡'].each do |name|
  result = candidates.call(by_name.fetch(name))
  check(nodes.first(3).all? { |node| result.include?(node) }, 'Ordinary sources excluded from automatic selection')
  check(!result.include?(nodes[3]) && !result.include?(nodes[4]), 'Metadata or special-purpose nodes included in automatic pool')
end

text = File.read(path)
check(!text.match?(/\/Users\/|subscription-token|[?&](?:token|key|auth)=|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i), 'Potential personal data or credentials')
config.fetch('rule-providers').each_value do |provider|
  uri = URI(provider.fetch('url'))
  check(uri.scheme == 'https' && uri.userinfo.nil? && uri.query.nil?, 'Rule provider must use a public URL without credentials')
end
puts JSON.pretty_generate(result: 'passed', groups: groups.length, rules: rules.length, subscription_urls: 0, static_nodes: 0, new_sources: 'discovered', dependencies: 'Ruby standard library only')
