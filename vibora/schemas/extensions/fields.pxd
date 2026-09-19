

cdef:
    str SOURCE_AUTO
    str SOURCE_JSON
    str SOURCE_FORM
    str SOURCE_QUERY
    str SOURCE_PATH


cdef class Field:
    cdef:
        readonly list validators
        public bint strict
        public bint is_async
        public str load_from
        public str load_into
        object default
        public bint required
        bint default_callable
        public str source


    cdef load(self, value)
    cdef sync_pipeline(self, object value, dict context)
    cdef _call_sync_validators(self, object value, dict context)


cdef class Integer(Field):
    pass


cdef class Number(Field):
    pass


cdef class String(Field):
    pass


cdef class List(Field):
    pass


cdef class Nested(Field):
    pass


cdef class File(Field):
    cdef:
        object allowed_mime_types
        int max_size

    cdef str _check_type(self, value)
    cdef _check_size(self, int size)
    cdef int _resolve_size_sync(self, value)
    cdef int _disk_size(self, value)
