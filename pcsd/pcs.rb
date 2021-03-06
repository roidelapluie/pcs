# Wrapper for PCS command
#

def getAllSettings()
  stdout, stderr, retval = run_cmd(PCS, "property")
  stdout.map(&:chomp!)
  stdout.map(&:strip!)
  stdout2, stderr2, retval2 = run_cmd(PENGINE, "metadata")
  metadata = stdout2.join
  ret = {}
  if retval == 0 and retval2 == 0
    doc = REXML::Document.new(metadata)

    default = ""
    el_type = ""
    doc.elements.each("resource-agent/parameters/parameter") { |e|
      name = e.attributes["name"]
      name.gsub!(/-/,"_")
      e.elements.each("content") { |c|
	default = c.attributes["default"]
	el_type = c.attributes["type"]
      }
      ret[name] = {"value" => default, "type" => el_type}
    }

    stdout.each {|line|
      key,val = line.split(': ', 2)
      key.gsub!(/-/,"_")
      if ret.has_key?(key)
	if ret[key]["type"] == "boolean"
	  val == "true" ?  ret[key]["value"] = true : ret[key]["value"] = false
	else
	  ret[key]["value"] = val
	end

      else
	ret[key] = {"value" => val, "type" => "unknown"}
      end
    }
    return ret
  end
  return {"error" => "Unable to get configuration settings"}
end

def add_location_constraint(resource, node, score)
  if node == ""
    return "Bad node"
  end

  if score == ""
    nodescore = node
  else
    nodescore = node +"="+score
  end

  stdout, stderr, retval = run_cmd(PCS,"constraint","location",resource,"prefers",nodescore)
  return retval
end

def add_order_constraint(resourceA, resourceB, score, symmetrical = true)
  sym = symmetrical ? "symmetrical" : "nonsymmetrical"
  if score != ""
    score = "score=" + score
  end
  $logger.info [PCS, "constraint", "order",  resourceA, "then", resourceB, score, sym]
  Open3.popen3(PCS, "constraint", "order", resourceA, "then",
	       resourceB, score, sym) { |stdin, stdout, stderror, waitth|
    $logger.info stdout.readlines()
    return waitth.value
  }
end

def add_colocation_constraint(resourceA, resourceB, score)
  if score == "" or score == nil
    score = "INFINITY"
  end
  $logger.info [PCS, "constraint", "colocation", "add", resourceA, resourceB, score]
  Open3.popen3(PCS, "constraint", "colocation", "add", resourceA,
	       resourceB, score) { |stdin, stdout, stderror, waitth|
    $logger.info stdout.readlines()
    return waitth.value
  }
end

def remove_constraint(constraint_id)
  stdout, stderror, retval = run_cmd(PCS, "constraint", "remove", constraint_id)
  $logger.info stdout
  return retval
end

def get_node_token(node)
  out, stderror, retval = run_cmd(PCS, "cluster", "token", node)
  return retval, out
end

# Gets all of the nodes specified in the pcs config file for the cluster
def get_cluster_nodes(cluster_name)
  pcs_config = PCSConfig.new
  clusters = pcs_config.clusters
  cluster = nil
  for c in clusters
    pp c.nodes
    pp c.name
    pp cluster_name
    if c.name == cluster_name
      cluster = c
      break
    end
  end

  if cluster && cluster.nodes != nil
    nodes = cluster.nodes
  else
    $logger.info "Error: no nodes found for #{cluster_name}"
    nodes = []
  end
  return nodes
end

def send_cluster_request_with_token(cluster_name, request, post=false, data={}, remote=true, raw_data=nil)
  out = ""
  code = 0
  nodes = get_cluster_nodes(cluster_name)

  for node in nodes
    code, out = send_request_with_token(node,request, post, data, remote=true, raw_data)
    $logger.info "Node: #{node} Request: #{request}"
    if out != '{"noresponse":true}'
      $logger.info "No response: Node: #{node} Request: #{request}"
      break
    end
  end
  return code,out
end

def send_request_with_token(node,request, post=false, data={}, remote=true, raw_data = nil)
  start = Time.now
  begin
    retval, token = get_node_token(node)
    token = token[0].strip
    if remote
      uri = URI.parse("https://#{node}:2224/remote/" + request)
    else
      uri = URI.parse("https://#{node}:2224/" + request)
    end

    logger.info "Sending Request: " + uri.to_s
    if post
      req = Net::HTTP::Post.new(uri.path)
      raw_data ? req.body = raw_data : req.set_form_data(data)
    else
      req = Net::HTTP::Get.new(uri.path)
      req.set_form_data(data)
    end
    $logger.info("Request: " + uri.to_s + " (" + (Time.now-start).to_s + "s)")
    req.add_field("Cookie","token="+token)
    myhttp = Net::HTTP.new(uri.host, uri.port)
    myhttp.use_ssl = true
    myhttp.verify_mode = OpenSSL::SSL::VERIFY_NONE
    res = myhttp.start do |http|
      http.read_timeout = 30 
      http.request(req)
    end
    return res.code.to_i, res.body
  rescue Exception => e
    $logger.info "No response from: #{node} request: #{request}"
    return 400,'{"noresponse":true}'
  end
end

def add_node(new_nodename,all = false, auto_start=true)
  if all
    if auto_start
      out, stderror, retval = run_cmd(PCS, "cluster", "node", "add", new_nodename, "--start")
    else
      out, stderror, retval = run_cmd(PCS, "cluster", "node", "add", new_nodename)
    end
  else
    out, stderror, retval = run_cmd(PCS, "cluster", "localnode", "add", new_nodename)
  end
  return retval, out.join("\n") + stderror.join("\n")
end

def remove_node(new_nodename, all = false)
  if all
    out, stderror, retval = run_cmd(PCS, "cluster", "node", "remove", new_nodename)
  else
    out, stderror, retval = run_cmd(PCS, "cluster", "localnode", "remove", new_nodename)
  end
  return retval, out + stderror
end

def get_corosync_nodes()
  stdout, stderror, retval = run_cmd(PCS, "status", "nodes", "corosync")
  if retval != 0
    return []
  end

  stdout.each {|x| x.strip!}
  corosync_online = stdout[1].sub(/^.*Online:/,"").strip
  corosync_offline = stdout[2].sub(/^.*Offline:/,"").strip
  corosync_nodes = (corosync_online.split(/ /)) + (corosync_offline.split(/ /))

  return corosync_nodes
end

# Get pacemaker nodes, but if they are not present fall back to corosync
def get_nodes()
  stdout, stderr, retval = run_cmd(PCS, "status", "nodes")
  if retval != 0
    stdout, stderr, retval = run_cmd(PCS, "status", "nodes", "corosync")
  end

  online = stdout[1]
  offline = stdout[2]

  if online
    online = online.split(' ')[1..-1].sort
  else
    online = []
  end

  if offline
    offline = offline.split(' ')[1..-1].sort
  else
    offline = []
  end

  [online, offline]
end

def get_resource_agents_avail()
  code, result = send_cluster_request_with_token(params[:cluster], 'get_avail_resource_agents')
  ra = JSON.parse(result)
  if (ra["noresponse"] == true)
    return {}
  else
    return ra
  end
end

def get_stonith_agents_avail()
  code, result = send_cluster_request_with_token(params[:cluster], 'get_avail_fence_agents')
  sa = JSON.parse(result)
  if (sa["noresponse"] == true)
    return {}
  else
    return sa
  end
end

def get_cluster_version()
  stdout, stderror, retval = run_cmd("corosync-cmapctl","totem.cluster_name")
  if retval != 0
    # Cluster probably isn't running, try to get cluster name from
    # corosync.conf
    begin
      corosync_conf = File.open("/etc/corosync/corosync.conf").read
    rescue
      return ""
    end
    in_totem = false
    current_level = 0
    corosync_conf.each_line do |line|
      if line =~ /totem\s*{/
        in_totem = true
      end
      if in_totem
        md = /cluster_name:\s*(\w+)/.match(line)
        if md
          return md[1]
        end
      end
      if in_totem and line =~ /}/
        in_totem = false
      end
    end

    return ""
  else
    return stdout.join().gsub(/.*= /,"").strip
  end
end

def enable_cluster()
  stdout, stderror, retval = run_cmd(PCS, "cluster", "enable")
  return false if retval != 0
  return true
end

def disable_cluster()
  stdout, stderror, retval = run_cmd(PCS, "cluster", "disable")
  return false if retval != 0
  return true
end

def run_cmd(*args)
  $logger.info("Running: " + args.join(" "))
  start = Time.now
  stdin, stdout, stderror, waitth = Open3.popen3(*args)
  out = stdout.readlines()
  errout = stderror.readlines()
  retval = waitth.value.exitstatus
  duration = Time.now - start
  $logger.debug("Return Value: " + retval.to_s)
  $logger.debug(out)
  $logger.debug("Duration: " + duration.to_s + "s")
  return out, errout, retval
end
