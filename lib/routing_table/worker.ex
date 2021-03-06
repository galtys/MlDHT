defmodule RoutingTable.Worker do
  @moduledoc false

  use GenServer

  require Logger
  require Bitwise

  alias RoutingTable.Node
  alias RoutingTable.Bucket
  alias RoutingTable.Distance

  #############
  # Constants #
  #############

  ## 5 Minutes
  @review_time 60 * 5

  ## 15 minutes
  @response_time 60 * 5

  ## 30 seconds
  @neighbourhood_maintenance_time 30

  ## 3 minutes
  @bucket_maintenance_time 60 * 1

  ##############
  # Public API #
  ##############

  def start_link(name) do
    Logger.debug "name: #{name}"
    GenServer.start_link(__MODULE__, ["AAAAAAAAAAAAAAAAAAAA"], name: name)
  end

  def add(name, remote_node_id, address, socket) do
    GenServer.call(name, {:add, remote_node_id, address, socket})
  end

  def node_id(name, node_id) do
    GenServer.call(name, {:node_id, node_id})
  end

  def node_id(name) do
    GenServer.call(name, :node_id)
  end

  def size(name) do
    GenServer.call(name, :size)
  end

  def print(name) do
    GenServer.cast(name, :print)
  end

  def get(name, node_id) do
    GenServer.call(name, {:get, node_id})
  end

  def get(name, node_id, address, socket) do
    GenServer.call(name, {:get, node_id, address, socket})
  end

  def closest_nodes(name, target) do
    GenServer.call(name, {:closest_nodes, target})
  end

  def del(name, node_id) do
    GenServer.call(name, {:del, node_id})
  end

  #################
  # GenServer API #
  #################

  def init([node_id]) do
    ## Start timer for peer review
    Process.send_after(self(), :review, @review_time * 1000)

    ## Start timer for neighbourhood maintenance
    Process.send_after(self(), :neighbourhood_maintenance,
                       @neighbourhood_maintenance_time * 1000)

    ## Start timer for bucket maintenance
    Process.send_after(self(), :bucket_maintenance, @bucket_maintenance_time *
                       1000)

    {:ok, %{node_id: node_id, buckets: [Bucket.new(0)]}}
  end


  @doc """
  This function gets called by an external timer. This function checks when was
  the last time a node has responded to our requests.
  """
  def handle_info(:review, state) do
    new_buckets = Enum.map(state[:buckets], fn(bucket) ->
      Bucket.filter(bucket, fn(pid) ->
        time = Node.last_time_responded(pid)
        cond do
          time < @response_time ->
            Node.send_ping(pid)

          time >= @response_time and Node.is_good?(pid) ->
            Node.goodness(pid, :questionable)
            Node.send_ping(pid)

          time >= @response_time and Node.is_questionable?(pid) ->
            Logger.debug "[#{Base.encode16 Node.id(pid)}] Deleted"
            Node.stop(pid)
            false
        end

      end)
    end)

    ## Restart the Timer
    Process.send_after(self(), :review, @review_time * 1000)

    {:noreply, [node_id: state[:node_id], buckets: new_buckets]}
  end

  @doc """
  This functions gets called by an external timer. This function takes a random
  node from a random bucket and runs a find_node query with our own node_id as a
  target. By that way, we try to find more and more nodes that are in our
  neighbourhood.
  """
  def handle_info(:neighbourhood_maintenance, state) do
    case random_node(state[:buckets]) do
      node_pid when is_pid(node_pid) ->
        Node.send_find_node(node_pid, Distance.gen_node_id(152, state[:node_id]))
      nil ->
        Logger.info "Neighbourhood Maintenance: No nodes in our routing table."
    end

    ## Restart the Timer
    Process.send_after(self(), :neighbourhood_maintenance,
                       @neighbourhood_maintenance_time * 1000)

    {:noreply, state}
  end

  @doc """
  This function gets called by an external timer. It iterates through all
  buckets and checks if a bucket has less than 6 nodes and not updated during
  the last 10 minutes. If this is the case, then we will pick a random node and
  start a find_node query with a random_node from that bucket.
  """
  def handle_info(:bucket_maintenance, state) do
    state[:buckets]
    |> Stream.with_index
    |> Enum.map(fn({bucket, index}) ->
      if Bucket.age(bucket) >= 600 and Bucket.size(bucket) < 6 do
        ## Pick a random node from our routing table and send a find_node
        ## request with a target from that bucket
        case random_node(state[:buckets]) do
          node_pid when is_pid(node_pid) ->
            Logger.debug "Index: #{index}"
            Node.send_find_node(node_pid, Distance.gen_node_id(index, state[:node_id]))
          nil ->
            Logger.info "Bucket Maintenance: No nodes in our routing table."
        end

      end
    end)

    Process.send_after(self(), :bucket_maintenance, @bucket_maintenance_time *
                       1000)

    {:noreply, state}
  end

  @doc """
  This function returns the 8 closest nodes in our routing table to a specific
  target.
  """
  def handle_call({:closest_nodes, target}, _from, state ) do
    list = state[:buckets]
    |> Enum.map(fn(bucket) -> bucket.nodes end)
    |> List.flatten
    |> Enum.sort(fn(x, y) -> Distance.xor_cmp(Node.id(x), Node.id(y), target, &(&1 < &2)) end)
    |> Enum.slice(0..7)

    {:reply, list, state}
  end

  @doc """
  This functiowe will ren returns the pid for a specific node id. If the node
  does not exists, it will try to add it to our routing table. Again, if this
  was successful, this function returns the pid, otherwise nil.
  """
  def handle_call({:get, node_id}, _from, state) do
    {:reply, get_node(state[:buckets], node_id), state}
  end

  def handle_call({:get, node_id, address, socket}, _from, state) do
    node_tuple = {node_id, address, socket}

    case get_node(state[:buckets], node_id) do
      node_pid when node_pid != nil ->
        {:reply, node_pid, state}
      _ ->
        new_buckets = add_node(state[:node_id], state[:buckets], node_tuple)
        node_pid = get_node(new_buckets, node_id)

        {:reply, node_pid, [node_id: state[:node_id], buckets: new_buckets]}
    end
  end

  @doc """
  This function returns the number of nodes in our routing table as an integer.
  """
  def handle_call(:size, _from, state) do
    size = state[:buckets]
    |> Enum.map(fn(b)-> Bucket.size(b) end)
    |> Enum.reduce(fn(x, acc) -> x + acc end)

    {:reply, size, state}
  end

  @doc """
  Without parameters this function returns our own node id. If this function
  gets a string as a parameter, it will set this as our node id.
  """
  def handle_call(:node_id, _from, state) do
    {:reply, state[:node_id], state}
  end

  def handle_call({:node_id, node_id}, _from, state) do
    {:reply, :ok, [node_id: node_id, buckets: state[:buckets]]}
  end

  @doc """
  This function tries to add a new node to our routing table. If it was
  sucessful, it returns the node pid and if not it will return nil.
  """
  def handle_call({:add, node_id, address, socket}, _from, state) do
    if not node_exists?(state[:buckets], node_id) do
      node_tuple = {node_id, address, socket}

      {:reply, :ok, [node_id: state[:node_id],
                     buckets: add_node(state[:node_id], state[:buckets], node_tuple)]}
    else
      {:reply, :ok, state}
    end
  end

  @doc """
  This function deletes a node according to its node id.
  """
  def handle_call({:del, node_id}, _from, state) do
    {:reply, :ok, [node_id: state[:node_id],
                   buckets: del_node(state[:buckets], node_id)]}
  end


  @doc """
  This function is for debugging purpose only. It prints out the complete
  routing table.
  """
  def handle_cast(:print, state) do
    state[:buckets]
    |> Enum.each(fn (bucket) ->
      Logger.debug inspect(bucket)
    end)

    {:noreply, state}
  end

  #####################
  # Private Functions #
  #####################

  @doc """
  This function adds a new node to our routing table.
  """
  def add_node(my_node_id, buckets, node) do
    index  = find_bucket_index(buckets, my_node_id, elem(node, 0))
    bucket = Enum.at(buckets, index)

    cond do
      ## If the bucket has still some space left, we can just add the node to
      ## the bucket. Easy Peasy
      Bucket.has_space?(bucket) ->
        new_bucket = Bucket.add(bucket, Node.start_link(my_node_id, node))
        List.replace_at(buckets, index, new_bucket)

        ## If the bucket is full and the node would belong to a bucket that is far
        ## away from us, we will just drop that node. Go away you filthy node!
        Bucket.is_full?(bucket) and index != index_last_bucket(buckets) ->
        Logger.debug "Bucket #{index} is full -> drop #{Base.encode16(elem(node, 0))}"
      buckets

      ## If the bucket is full but the node is closer to us, we will reorganize
      ## the nodes in the buckets and try again to add it to our bucket list.
      true ->
          buckets = reorganize(bucket.nodes, buckets ++ [Bucket.new(index + 1)], my_node_id)
          add_node(my_node_id, buckets, node)
    end
  end

  @doc """
  TODO
  """
  def reorganize([], buckets, _self_node_id), do: buckets
  def reorganize([node | rest], buckets, my_node_id) do
    current_index  = length(buckets) - 2
    index          = find_bucket_index(buckets, my_node_id, Node.id(node))

    new_buckets = if (current_index != index) do
      current_bucket = Enum.at(buckets, current_index)
      new_bucket     = Enum.at(buckets, index)

      ## Remove the node from the current bucket
      filtered_bucket = Bucket.del(current_bucket, Node.id(node))

      ## Then add it to the new_bucket
      List.replace_at(buckets, current_index, filtered_bucket)
      |> List.replace_at(index, Bucket.add(new_bucket, node))
    else
      buckets
    end

    reorganize(rest, new_buckets, my_node_id)
  end

  @doc """
  This function returns a random node pid. If the routing table is empty it
  returns nil.
  """
  def random_node(buckets) do
    nodes = buckets
    |> Enum.map(fn(bucket) -> bucket.nodes end)
    |> List.flatten

    unless Enum.empty?(nodes) do
      Enum.random(nodes)
    else
      nil
    end
  end


  @doc """
  Returns the index of the last bucket as integer.
  """
  def index_last_bucket(buckets) do
    Enum.count(buckets) -1
  end

  @doc """
  TODO
  """
  def find_bucket_index(buckets, self_node_id, remote_node_id) do
    unless byte_size(self_node_id) == byte_size(remote_node_id) do
      Logger.error "self_node_id: #{String.length(self_node_id)}
      remote_node_id: #{String.length(remote_node_id)}"
      raise ArgumentError, message: "Different length of self_node_id and remote_node_id"
    end
    bucket_index = Distance.find_bucket(self_node_id, remote_node_id)

    min(bucket_index, index_last_bucket(buckets))
  end

  @doc """
  TODO
  """
  def node_exists?(buckets, node_id) do
    Enum.any?(buckets, fn(bucket) ->
      Bucket.node_exists?(bucket, node_id)
    end)
  end

  @doc """
  TODO
  """
  def del_node(buckets, node_id) do
    Enum.map(buckets, fn(bucket) ->
      Bucket.del(bucket, node_id)
    end)
  end

  @doc """

  """
  def get_node(buckets, node_id) do
    Enum.map(buckets, fn(bucket) ->
      Bucket.get(bucket, node_id)
    end) |> Enum.find(fn(x) -> Kernel.is_pid(x) end)
  end

end
