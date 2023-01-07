import deques, asyncdispatch

type
  ResourcePool*[T] = ref object
    resources: Deque[T]
    queuers: Deque[Future[T]]

proc dequeue*[T](pool: ResourcePool[T]): Future[T] = 
  result = newFuture[T]("dequeue")
  if pool.resources.len == 0:
    pool.queuers.addLast result
  else:
    result.complete pool.resources.popFirst()

proc enqueue*[T](pool: ResourcePool[T], item: T) =
  if pool.queuers.len > 0:
    let fut = pool.queuers.popFirst()
    fut.complete(item)
  else:
    pool.resources.addLast(item)

# ----

import httpclient

type
  AsyncHttpClientPool* = ResourcePool[AsyncHttpClient]

proc newAsyncHttpClientPool*(size: int): AsyncHttpClientPool =
  result.new()
  for i in 1..size: result.enqueue(newAsyncHttpClient())