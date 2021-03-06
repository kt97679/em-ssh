module EventMachine
  class Ssh
    class PacketStream
      include Net::SSH::BufferedIo
      include Log


      # The map of "hints" that can be used to modify the behavior of the packet
      # stream. For instance, when authentication succeeds, an "authenticated"
      # hint is set, which is used to determine whether or not to compress the
      # data when using the "delayed" compression algorithm.
      attr_reader :hints

      # The server state object, which encapsulates the algorithms used to interpret
      # packets coming from the server.
      attr_reader :server

      # The client state object, which encapsulates the algorithms used to build
      # packets to send to the server.
      attr_reader :client

      # The input stream
      attr_reader :input
      # The output stream
      attr_reader :output

      def initialize(connection)
        @connection = connection
        @input      = Net::SSH::Buffer.new
        @output     = Net::SSH::Buffer.new
        @hints      = {}
        @server     = Net::SSH::Transport::State.new(self, :server)
        @client     = Net::SSH::Transport::State.new(self, :client)
        @packet     = nil
      end # initialize(content="")

      def close
        # remove reference to the connection to facilitate Garbage Collection
        return super.tap { @connection = nil } if respond_to?(:super)
        @connection = nil
      end

      # Consumes n bytes from the buffer, where n is the current position
      # unless otherwise specified. This is useful for removing data from the
      # buffer that has previously been read, when you are expecting more data
      # to be appended. It helps to keep the size of buffers down when they
      # would otherwise tend to grow without bound.
      #
      # Returns the buffer object itself.
      def consume!(*args)
        input.consume!(*args)
      end # consume!(*args)

      # Tries to read the next packet. If there is insufficient data to read
      # an entire packet, this returns immediately, otherwise the packet is
      # read, post-processed according to the cipher, hmac, and compression
      # algorithms specified in the server state object, and returned as a
      # new Packet object.
      # Copyright (c) 2008 Jamis Buck
      def poll_next_packet
        if @packet.nil?
          minimum = server.block_size < 4 ? 4 : server.block_size
          return nil if available < minimum
          data = read_available(minimum)
          # decipher it
          @packet = Net::SSH::Buffer.new(server.update_cipher(data))
          @packet_length = @packet.read_long
        end
        need = @packet_length + 4 - server.block_size
        if need % server.block_size != 0
          @connection.fire(:error, SshError.new("padding error, need #{need} block #{server.block_size}"))
        end

        return nil if available < need + server.hmac.mac_length

        if need > 0
          # read the remainder of the packet and decrypt it.
          data = read_available(need)
          @packet.append(server.update_cipher(data))
        end

        # get the hmac from the tail of the packet (if one exists), and
        # then validate it.
        real_hmac = read_available(server.hmac.mac_length) || ""

        @packet.append(server.final_cipher)
        padding_length = @packet.read_byte

        payload = @packet.read(@packet_length - padding_length - 1)
        padding = @packet.read(padding_length) if padding_length > 0

        my_computed_hmac = server.hmac.digest([server.sequence_number, @packet.content].pack("NA*"))
        if real_hmac != my_computed_hmac
          @connection.fire(:error, Net::SSH::Exception.new("corrupted mac detected"))
          return
        end

        # try to decompress the payload, in case compression is active
        payload = server.decompress(payload)

        log.debug("received packet nr #{server.sequence_number} type #{payload.getbyte(0)} len #{@packet_length}")

        server.increment(@packet_length)
        @packet = nil

        return Net::SSH::Packet.new(payload)
      end # poll_next_packet

      # Copyright (c) 2008 Jamis Buck
      def send_packet(payload)
        # try to compress the packet
        payload = client.compress(payload)

        # the length of the packet, minus the padding
        actual_length = 4 + payload.length + 1

        # compute the padding length
        padding_length = client.block_size - (actual_length % client.block_size)
        padding_length += client.block_size if padding_length < 4

        # compute the packet length (sans the length field itself)
        packet_length = payload.length + padding_length + 1
        if packet_length < 16
          padding_length += client.block_size
          packet_length = payload.length + padding_length + 1
        end

        padding = Array.new(padding_length) { rand(256) }.pack("C*")

        unencrypted_data = [packet_length, padding_length, payload, padding].pack("NCA*A*")
        mac = client.hmac.digest([client.sequence_number, unencrypted_data].pack("NA*"))

        encrypted_data = client.update_cipher(unencrypted_data) << client.final_cipher
        message = encrypted_data + mac

        log.debug("queueing packet nr #{client.sequence_number} type #{payload.getbyte(0)} len #{packet_length}")
        @connection.send_data(message)
        log.debug("sent #{message.length} bytes")
        client.increment(packet_length)

        self
      end # send_packet(payload)

      # Performs any pending cleanup necessary on the IO and its associated
      # state objects. (See State#cleanup).
      def cleanup
        client.cleanup
        server.cleanup
      end

      # If the IO object requires a rekey operation (as indicated by either its
      # client or server state objects, see State#needs_rekey?), this will
      # yield. Otherwise, this does nothing.
      # Copyright (c) 2008 Jamis Buck
      def if_needs_rekey?
        if client.needs_rekey? || server.needs_rekey?
          yield
          client.reset! if client.needs_rekey?
          server.reset! if server.needs_rekey?
        end
      end
    end # class::PacketStream
  end # class::Ssh
end # module::EventMachine
