# This file is a part of Julia. License is MIT: https://julialang.org/license

mutable struct PipeServer <: LibuvServer
    handle::Ptr{Cvoid}
    status::Int
    connectnotify::Condition
    closenotify::Condition
    function PipeServer(handle::Ptr{Cvoid}, status)
        p = new(handle,
                status,
                Condition(),
                Condition())
        associate_julia_struct(p.handle, p)
        finalizer(uvfinalize, p)
        return p
    end
end

function PipeServer()
    pipe = PipeServer(Libc.malloc(Base._sizeof_uv_named_pipe), StatusUninit)
    err = ccall(:uv_pipe_init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Cint), eventloop(), pipe.handle, 0)
    uv_error("failed to create pipe server", err)
    pipe.status = StatusInit
    return pipe
end

## server functions ##

accept(server::PipeServer) = accept(server, PipeEndpoint())

function accept_nonblock(server::PipeServer, client::PipeEndpoint)
    if client.status != StatusInit
        error("client is already in use or has been closed")
    end
    err = ccall(:uv_accept, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), server.handle, client.handle)
    if err == 0
        client.status = StatusOpen
    end
    return err
end

function accept_nonblock(server::PipeServer)
    client = PipeEndpoint()
    uv_error("accept", accept_nonblock(server, client) != 0)
    return client
end

function accept(server::LibuvServer, client::LibuvStream)
    if server.status != StatusActive
        throw(ArgumentError("server not connected, make sure \"listen\" has been called"))
    end
    while isopen(server)
        err = accept_nonblock(server, client)
        if err == 0
            return client
        elseif err != UV_EAGAIN
            uv_error("accept", err)
        end
        stream_wait(server, server.connectnotify)
    end
    uv_error("accept", UV_ECONNABORTED)
end

const BACKLOG_DEFAULT = 511

function listen(sock::LibuvServer; backlog::Integer=BACKLOG_DEFAULT)
    uv_error("listen", trylisten(sock))
    return sock
end

function trylisten(sock::LibuvServer; backlog::Integer=BACKLOG_DEFAULT)
    check_open(sock)
    err = ccall(:uv_listen, Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}),
                sock, backlog, Base.uv_jl_connectioncb::Ptr{Cvoid})
    sock.status = StatusActive
    return err
end

function bind(server::PipeServer, name::AbstractString)
    @assert server.status == StatusInit
    err = ccall(:uv_pipe_bind, Int32, (Ptr{Cvoid}, Cstring),
                server, name)
    if err != 0
        if err != UV_EADDRINUSE && err != UV_EACCES
            #TODO: this codepath is currently not tested
            throw(UVError("bind",err))
        else
            return false
        end
    end
    server.status = StatusOpen
    return true
end

"""
    listen(path::AbstractString) -> PipeServer

Create and listen on a named pipe / UNIX domain socket.
"""
function listen(path::AbstractString)
    sock = PipeServer()
    bind(sock, path) || throw(ArgumentError("could not listen on path $path"))
    return listen(sock)
end

function connect!(sock::PipeEndpoint, path::AbstractString)
    @assert sock.status == StatusInit
    req = Libc.malloc(Base._sizeof_uv_connect)
    uv_req_set_data(req, C_NULL)
    ccall(:uv_pipe_connect, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Ptr{Cvoid}), req, sock.handle, path,
          Base.uv_jl_connectcb::Ptr{Cvoid})
    sock.status = StatusConnecting
    return sock
end

function connect(sock::LibuvStream, args...)
    connect!(sock, args...)
    wait_connected(sock)
    return sock
end

# Libuv will internally reset read/writability, which is uses to
# mark that this is an invalid pipe.

"""
    connect(path::AbstractString) -> PipeEndpoint

Connect to the named pipe / UNIX domain socket at `path`.
"""
connect(path::AbstractString) = connect(PipeEndpoint(), path)
