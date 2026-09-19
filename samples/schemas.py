from vibora import Vibora, Request
from vibora.responses import JsonResponse
from vibora.schemas import Schema, fields
from vibora.schemas.exceptions import InvalidSchema

app = Vibora()


# ---------------------------------------------------------------------------
# 1. JSON body (classic usage, unchanged).
# ---------------------------------------------------------------------------
class BenchmarkSchema(Schema):
    field1: str = fields.String(required=True)
    field2: int = fields.Integer(required=True)


@app.route('/json', methods=['POST'])
async def json_endpoint(request: Request):
    try:
        values = await BenchmarkSchema.load_json(request)
        return JsonResponse({'msg': 'Successfully validated',
                             'field1': values.field1,
                             'field2': values.field2})
    except InvalidSchema as error:
        return JsonResponse({'msg': 'Data is invalid', 'errors': error.errors}, status_code=400)


# ---------------------------------------------------------------------------
# 2. URL query string parameters.
#
# Each field declares source=fields.Sources.QUERY (the alias
# fields.Location.QUERY is also available). Fields without an explicit source
# default to "auto" and follow the primary source of the loader being used.
# ---------------------------------------------------------------------------
class SearchSchema(Schema):
    query: str = fields.String(source=fields.Sources.QUERY)
    page: int = fields.Integer(source=fields.Sources.QUERY, default=1)
    page_size: int = fields.Integer(source=fields.Sources.QUERY, default=20)


@app.route('/search', methods=['GET'])
async def search_endpoint(request: Request):
    try:
        values = await SearchSchema.load_query(request)
        return JsonResponse({'query': values.query,
                             'page': values.page,
                             'page_size': values.page_size})
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)


# ---------------------------------------------------------------------------
# 3. Dynamic route path parameters.
#
# The router extracts the raw URL fragments and hands them to the schema
# through load_path(). The Integer field casts the string fragment for us.
# load_from keeps working if the schema attribute has a different name.
# ---------------------------------------------------------------------------
class UserPathSchema(Schema):
    user_id: int = fields.Integer(source=fields.Sources.PATH)
    tab: str = fields.String(source=fields.Sources.PATH, default='profile')


@app.route('/users/<user_id>/<tab>')
async def user_endpoint(request: Request, user_id: str, tab: str):
    try:
        values = await UserPathSchema.load_path(request, path_params={
            'user_id': user_id,
            'tab': tab
        })
        return JsonResponse({'user_id': values.user_id, 'tab': values.tab})
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)


# ---------------------------------------------------------------------------
# 4. Mixed sources in a single schema.
#
# Calling Schema.load(request) auto-detects the primary source from the
# request Content-Type (form or JSON) while individual fields can still pull
# from the query string or path parameters.
# ---------------------------------------------------------------------------
class CreateCommentSchema(Schema):
    # Comes from the JSON body or the form (primary source).
    body: str = fields.String(required=True)
    # Comes from the query string regardless of the primary source.
    notify: str = fields.String(source=fields.Sources.QUERY, default='0')
    # Comes from a dynamic route fragment.
    post_id: int = fields.Integer(source=fields.Sources.PATH)


@app.route('/posts/<post_id>/comments', methods=['POST'])
async def create_comment(request: Request, post_id: str):
    try:
        values = await CreateCommentSchema.load(
            request, context={'path_params': {'post_id': post_id}}
        )
        return JsonResponse({'post_id': values.post_id,
                             'body': values.body,
                             'notify': values.notify})
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)


# ---------------------------------------------------------------------------
# 5. File uploads with a MIME white list and a maximum size.
#
# fields.File extracts multipart/form-data uploads and validates:
#   * the value is actually an uploaded file;
#   * the detected MIME type is in allowed_mime_types;
#   * the file size in bytes does not exceed max_size.
# On success the attribute is a fields.FileInfo exposing filename,
# content_type, size, read(), save() and seek().
# ---------------------------------------------------------------------------
class AvatarUploadSchema(Schema):
    avatar: fields.FileInfo = fields.File(
        allowed_mime_types=['image/png', 'image/jpeg', 'image/gif'],
        max_size=2 * 1024 * 1024  # 2 MB
    )
    description: str = fields.String(required=False, default='')


@app.route('/avatar', methods=['POST'])
async def avatar_endpoint(request: Request):
    try:
        values = await AvatarUploadSchema.load_form(request)
        content = await values.avatar.read()
        # You could also stream it to disk: await values.avatar.save('/path/file.png')
        return JsonResponse({
            'filename': values.avatar.filename,
            'content_type': values.avatar.content_type,
            'size': values.avatar.size,
            'received_bytes': len(content),
            'description': values.description
        })
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)


if __name__ == '__main__':
    app.run(debug=True, port=8000, host='0.0.0.0', workers=8)
