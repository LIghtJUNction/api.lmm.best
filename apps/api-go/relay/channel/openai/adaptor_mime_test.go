package openai

import (
	"bytes"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	relaycommon "github.com/LIghtJUNction/api.lmm.best/relay/common"
	relayconstant "github.com/LIghtJUNction/api.lmm.best/relay/constant"
	"github.com/LIghtJUNction/api.lmm.best/relaykit/dto"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestDetectImageMimeType(t *testing.T) {
	tests := []struct {
		name     string
		filename string
		wantType string
		wantErr  string
	}{
		{name: "jpeg uppercase", filename: "input.JPEG", wantType: "image/jpeg"},
		{name: "jpg uppercase", filename: "input.JPG", wantType: "image/jpeg"},
		{name: "png uppercase", filename: "input.PNG", wantType: "image/png"},
		{name: "webp uppercase", filename: "input.WEBP", wantType: "image/webp"},
		{
			name:     "heic is unsupported",
			filename: "input.HEIC",
			wantErr:  `unsupported image format ".heic"; supported formats: .jpg, .jpeg, .png, .webp`,
		},
		{
			name:     "extensionless is unsupported",
			filename: "input",
			wantErr:  `unsupported image format ""; supported formats: .jpg, .jpeg, .png, .webp`,
		},
		{
			name:     "unknown extension is unsupported",
			filename: "input.gif",
			wantErr:  `unsupported image format ".gif"; supported formats: .jpg, .jpeg, .png, .webp`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := detectImageMimeType(tt.filename)
			if tt.wantErr != "" {
				require.EqualError(t, err, tt.wantErr)
				require.Empty(t, got)
				return
			}

			require.NoError(t, err)
			require.Equal(t, tt.wantType, got)
		})
	}
}

func TestConvertImageRequestRejectsUnsupportedImageFormat(t *testing.T) {
	gin.SetMode(gin.TestMode)

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	require.NoError(t, writer.WriteField("model", "gpt-image-1"))
	part, err := writer.CreateFormFile("image", "input.heic")
	require.NoError(t, err)
	_, err = part.Write([]byte("fake image"))
	require.NoError(t, err)
	require.NoError(t, writer.Close())

	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/images/edits", &body)
	c.Request.Header.Set("Content-Type", writer.FormDataContentType())
	require.NoError(t, c.Request.ParseMultipartForm(32<<20))

	info := &relaycommon.RelayInfo{RelayMode: relayconstant.RelayModeImagesEdits}
	converted, err := (&Adaptor{}).ConvertImageRequest(c, info, dto.ImageRequest{Model: "gpt-image-1"})

	require.Nil(t, converted)
	require.EqualError(t, err, `unsupported image format ".heic"; supported formats: .jpg, .jpeg, .png, .webp`)
}
