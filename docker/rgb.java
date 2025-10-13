package com.jci.mediaprocessor.media_processor;

import android.opengl.GLES20;
import android.opengl.GLES30;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;

public class RgbRenderer extends BaseRenderer {
  private static final String LOG_TAG = "RgbRenderer";

  private ByteBuffer mBufferRGB; // direct or wrapped

  public RgbRenderer(Surface surface, int width, int height) {
    super(surface, width, height);
  }

  @Override
  protected String vertexShader() {
    return "attribute vec4 a_Position;\n"
         + "attribute vec2 a_TexCoordinate;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main(){\n"
         + "  v_TexCoordinate = a_TexCoordinate;\n"
         + "  gl_Position = a_Position;\n"
         + "}";
  }

  @Override
  protected String fragmentShader() {
    return "precision mediump float;\n"
         + "uniform sampler2D sampler;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main(){\n"
         + "  gl_FragColor = vec4(texture2D(sampler, v_TexCoordinate).rgb, 1.0);\n"
         + "}";
  }

  @Override
  protected void connectTexturesToProgram() {
    mYUVTextureHandle[0] = GLES20.glGetUniformLocation(mProgramHandle, "sampler");
  }

  @Override
  public void setBuffer(byte[] inRgb, byte[] unusedU, byte[] unusedV) {
    // Java-side data (copy); fine for testing or if upstream provides it
    mBufferRGB = ByteBuffer.wrap(inRgb);
    drawTexture();
  }

  @Override
  public void setBufferPtr(long ptr, int size) {
    // Zero-copy wrap of native memory -> direct ByteBuffer (lifetime must outlive upload)
    mBufferRGB = getBufferDirect(ptr, size);
    drawTexture();
  }

  @Override
  protected void loadTexture(ByteBuffer[] buffers) {
    ByteBuffer buf = buffers[0];

    GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, mTextures[0]);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);

    GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D,
        0,
        GLES20.GL_RGBA,
        width,
        height,
        0,
        GLES20.GL_RGBA,
        GLES20.GL_UNSIGNED_BYTE,
        buf);

    GLES20.glUniform1i(mYUVTextureHandle[0], 0);
  }

  @Override
  protected void drawTexture() {
    if (mBufferRGB == null) return;

    GLES20.glClearColor(0f, 0f, 0f, 1f);
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);

    loadTexture(new ByteBuffer[]{ mBufferRGB });

    GLES20.glUseProgram(mProgramHandle);
    GLES30.glBindVertexArray(vao[0]);
    GLES20.glDrawElements(GLES20.GL_TRIANGLES, 6, GLES20.GL_UNSIGNED_INT, 0);

    if (!egl.eglSwapBuffers(eglDisplay, eglSurface)) {
      Log.d(LOG_TAG, "eglSwapBuffers error: " + egl.eglGetError());
    }
  }
}
