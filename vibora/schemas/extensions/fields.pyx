import mimetypes
import os
from ..exceptions import ValidationError, NestedValidationError
from ..messages import Messages
from ...multipart import UploadedFile, MemoryFile, DiskFile
from .validator cimport Validator


# Input source identifiers used by Schema.load() to route each field
# to the data source it must be extracted from.
BODY = 'body'
QUERY = 'query'
PATH = 'path'
DEFAULT_SOURCE = BODY


cdef class Field:
    def __init__(self, bint required=True, object default=None, list validators=None,
                 bint strict=False, str load_from=None, str source=DEFAULT_SOURCE):
        self.validators = validators or []
        self.strict = strict
        self.is_async = False
        self.load_from = load_from
        self.load_into = None
        self.source = source
        self.default = default
        self.required = required if default is None else False
        self.default_callable = callable(self.default)

    cdef load(self, value):
        return value

    async def pipeline(self, value, context: dict):
        """

        :param context:
        :param value:
        :return:
        """
        value = self.load(value)
        if self.validators:
            await self._call_validators(value, context)
        return value

    cdef sync_pipeline(self, value, dict context):
        """

        :param context:
        :param value:
        :return:
        """
        value = self.load(value)
        if self.validators:
            self._call_sync_validators(value, context)
        return value

    async def _call_validators(self, value, context: dict):
        """

        :param value:
        :param context:
        :return:
        """
        cdef Validator validator
        for validator in self.validators:
            if validator.is_async:
                await validator.validate(value, context)
            else:
                validator.validate(value, context)

    cdef _call_sync_validators(self, value, context: dict):
        """

        :param value:
        :param context:
        :return:
        """
        cdef Validator validator
        for validator in self.validators:
            validator.validate(value, context)


cdef class String(Field):

    cdef load(self, value):
        """

        :param value:
        :return:
        """
        if isinstance(value, str):
            return value
        elif self.strict and not isinstance(value, (int, float)):
            raise ValidationError(error_code=Messages.MUST_BE_STRING)
        return str(value)


cdef class Integer(Field):

    cdef load(self, value):
        """

        :param value:
        :return:
        """
        if isinstance(value, int):
            return value
        elif self.strict and not isinstance(value, (str, float)):
            raise ValidationError(error_code=Messages.MUST_BE_INTEGER, field=self.load_from)
        try:
            return int(value)
        except ValueError:
            raise ValidationError(error_code=Messages.MUST_BE_INTEGER, field=self.load_from)


cdef class Number(Field):

    cdef load(self, value):
        """

        :param value:
        :return:
        """
        if isinstance(value, int):
            return value
        elif self.strict:
            raise ValidationError(error_code=Messages.MUST_BE_NUMBER, field=self.load_from)
        try:
            return float(value)
        except ValueError:
            raise ValidationError(error_code=Messages.MUST_BE_NUMBER, field=self.load_from)


cdef class List(Field):

    def __init__(self, field, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.field = field

    async def pipeline(self, value, context):
        """

        :param value:
        :return:
        """
        if not isinstance(value, list):
            raise ValidationError(Messages.MUST_BE_LIST)
        processed_list = []
        for index, item in enumerate(value):
            try:
                if self.field.is_async:
                    processed_list.append(await self.field.async_pipeline(item))
                else:
                    processed_list.append(self.field.pipeline(item))
            except ValidationError as error:
                raise ValidationError(f'{index}º element: {error.msg}', field=self.load_from)
        value = processed_list
        if self.validators:
            await self._call_validators(value, context)
        return value


cdef class Nested(Field):

    def __init__(self, schema, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.schema = schema

    async def pipeline(self, value, context: dict):
        """

        :param context:
        :param value:
        :return:
        """
        if not isinstance(value, dict):
            raise ValidationError(error_code=Messages.MUST_BE_DICT, field=self.load_from)
        nested_context = await self.schema.load(value, silent=True)
        if nested_context.errors:
            raise NestedValidationError(context=nested_context.context)
        value = nested_context.data
        if self.validators:
            await self._call_validators(value, context)
        return value

    cdef sync_pipeline(self, value, dict context):
        """

        :param context:
        :param value:
        :return:
        """
        if not isinstance(value, dict):
            raise ValidationError(error_code=Messages.MUST_BE_DICT, field=self.load_from)
        nested_context = self.schema.load(value, silent=True)
        if nested_context.errors:
            raise NestedValidationError(context=nested_context.context)
        value = nested_context.data
        if self.validators:
            self._call_validators(value, context)
        return value

cdef class File(Field):

    def __init__(self, allowed_mime_types=None, object max_size=10 * 1024 * 1024,
                 bint required=True, object default=None, list validators=None,
                 str load_from=None, str source=DEFAULT_SOURCE):
        super().__init__(required=required, default=default, validators=validators,
                         load_from=load_from, source=source)
        self.allowed_mime_types = None
        if allowed_mime_types is not None:
            self.allowed_mime_types = []
            for mime_type in allowed_mime_types:
                if '/' not in mime_type:
                    raise ValueError('Invalid MIME type "{0}".'.format(mime_type))
                self.allowed_mime_types.append(mime_type.lower())
        self.max_size = max_size

    cdef load(self, value):
        if not isinstance(value, UploadedFile):
            raise ValidationError(
                'Field "{0}" expects a file uploaded through multipart/form-data.'.format(self.load_from),
                field=self.load_from
            )
        if self.allowed_mime_types is not None:
            guessed_mime_type, _ = mimetypes.guess_type(value.filename or '')
            if guessed_mime_type is None or guessed_mime_type.lower() not in self.allowed_mime_types:
                raise ValidationError(
                    'File type "{0}" is not allowed. Allowed types: {1}.'.format(
                        guessed_mime_type or 'application/octet-stream',
                        ', '.join(self.allowed_mime_types)
                    ),
                    field=self.load_from
                )
        size = _uploaded_file_size(value)
        if self.max_size is not None and size is not None and size > self.max_size:
            raise ValidationError(
                'File "{0}" exceeds the maximum allowed size of {1} bytes (got {2} bytes).'.format(
                    value.filename, self.max_size, size
                ),
                field=self.load_from
            )
        return UploadedFileValue(value)


def _uploaded_file_size(value):
    """Best-effort size retrieval for the uploaded file objects exposed by
    the multipart parser without forcing the content to be consumed."""
    if isinstance(value, MemoryFile):
        return len(value.f)
    if isinstance(value, DiskFile):
        try:
            return os.path.getsize(value.temporary_path)
        except OSError:
            return None
    return None


class UploadedFileValue:
    """File metadata plus a reference to the underlying content stream
    produced by a multipart/form-data upload."""

    def __init__(self, file):
        self.file = file
        self.filename = file.filename
        self.size = _uploaded_file_size(file)

    @property
    def content_type(self):
        guessed, _ = mimetypes.guess_type(self.filename or '')
        return guessed or 'application/octet-stream'

    async def read(self, count: int=0) -> bytes:
        return await self.file.read(count)

    async def save(self, destination: str):
        return await self.file.save(destination)

    def seek(self, pos):
        self.file.seek(pos)
        return self

    def __aiter__(self):
        # Default 1 MiB chunk size; call .chunks(size) explicitly to override.
        return UploadedFileChunks(self, 1024 * 1024)

    def chunks(self, chunk_size: int=1024 * 1024):
        return UploadedFileChunks(self, chunk_size)


class UploadedFileChunks:
    """Async iterator over the uploaded file content without loading the
    whole payload into memory."""

    def __init__(self, uploaded_file, chunk_size: int):
        self.uploaded_file = uploaded_file
        self.chunk_size = chunk_size

    def __aiter__(self):
        return self

    async def __anext__(self):
        chunk = await self.uploaded_file.file.read(self.chunk_size)
        if not chunk:
            raise StopAsyncIteration
        return chunk
