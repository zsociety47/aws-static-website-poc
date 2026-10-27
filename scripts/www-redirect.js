// Viewer request function. www.example.com returns a 301 to example.com.
// The hostname is read from the request, so the domain is not written here.
function handler(event) {
    var request = event.request;
    var host = request.headers.host.value;
    if (host.length > 4 && host.slice(0, 4) === 'www.') {
        var qs = [];
        var params = request.querystring || {};
        for (var key in params) {
            if (params[key] && params[key].value) {
                qs.push(key + '=' + params[key].value);
            }
        }
        var suffix = qs.length ? '?' + qs.join('&') : '';
        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: {
                location: { value: 'https://' + host.slice(4) + request.uri + suffix }
            }
        };
    }
    return request;
}
