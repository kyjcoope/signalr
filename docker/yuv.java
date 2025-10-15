package com.jci.mediaprocessor.media_processor;

import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.view.Surface;

import java.nio.ByteBuffer;

public class YuvRenderer extends BaseRenderer {
  private ByteBuffer mBufferY, mBufferU, mBufferV;

  public YuvRenderer(Surface surface, int width, int height) { super(surface, width, height); }
  public YuvRenderer(SurfaceTexture texture, int width, int height) { super(texture, width, height); }

  public String vertexShader() {
    return "attribute vec4 a_Position;\n"
         + "attribute vec2 a_TexCoordinate;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main(){ v_TexCoordinate = a_TexCoordinate; gl_Position = a_Position; }";
  }

  public String fragmentShader() {
    return "precision mediump float;\n"
         + "uniform sampler2D samplerY;\n"
         + "uniform sampler2D samplerU;\n"
         + "uniform sampler2D samplerV;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main(){\n"
         + "  float y = texture2D(samplerY, v_TexCoordinate).r - (16.0/255.0);\n"
         + "  float u = texture2D(samplerU, v_TexCoordinate).r - (128.0/255.0);\n"
         + "  float v = texture2D(samplerV, v_TexCoordinate).r - (128.0/255.0);\n"
         + "  mat3 m = mat3(1.164, 1.164, 1.164, 0.0, -0.392, 2.017, 1.596, -0.813, 0.0);\n"
         + "  vec3 rgb = m * vec3(y, u, v);\n"
         + "  gl_FragColor = vec4(rgb, 1.0);\n"
         + "}";
  }

  protected void connectTexturesToProgram() {
    mYUVTextureHandle[0] = GLES20.glGetUniformLocation(mProgramHandle, "samplerY");
    mYUVTextureHandle[1] = GLES20.glGetUniformLocation(mProgramHandle, "samplerU");
    mYUVTextureHandle[2] = GLES20.glGetUniformLocation(mProgramHandle, "samplerV");
  }

  public void setBuffer(byte[] inY, byte[] inU, byte[] inV) {
    mBufferY = ByteBuffer.wrap(inY);
    mBufferU = ByteBuffer.wrap(inU);
    mBufferV = ByteBuffer.wrap(inV);
    drawTexture();
  }

  public void setBufferPtr(long ptr, int size) {
    // No-op in your YUV path at present
  }

  protected void loadTexture(ByteBuffer[] buffers) {
    int[] w = { width, width / 2, width / 2 };
    int[] h = { height, height / 2, height / 2 };

    for (int i = 0; i < 3; i++) {
      GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + i);
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, mTextures[i]);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);

      GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, w[i], h[i], 0,
                          GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, buffers[i]);

      GLES20.glUniform1i(mYUVTextureHandle[i], i);
    }
  }

  public void drawTexture() {
    GLES20.glClearColor(0f, 0f, 0f, 1f);
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT | GLES20.GL_DEPTH_BUFFER_BIT);

    loadTexture(new ByteBuffer[]{ mBufferY, mBufferU, mBufferV });

    GLES20.glUseProgram(mProgramHandle);
    GLES30.glBindVertexArray(0);
    GLES20.glDrawElements(GLES20.GL_TRIANGLES, 6, GLES20.GL_UNSIGNED_INT, 0);

    present();
  }
}
