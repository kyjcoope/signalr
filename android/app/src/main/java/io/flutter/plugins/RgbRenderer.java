package com.jci.mediaprocessor.media_processor;

import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.util.Log;

import java.nio.ByteBuffer;

public class RgbRenderer extends BaseRenderer {

  private ByteBuffer mBufferRGB;
  private byte[] mBytes = null;
  private long mPtr = 0;

  public RgbRenderer(SurfaceTexture texture, int width, int height) {
    super(texture, width, height);
  }

  @Override
  protected String vertexShader() {
    return "attribute vec4 a_Position;\n"
         + "attribute vec2 a_TexCoordinate;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main() {\n"
         + "  v_TexCoordinate = a_TexCoordinate;\n"
         + "  gl_Position = a_Position;\n"
         + "}\n";
  }

  @Override
  protected String fragmentShader() {
    return "precision mediump float;\n"
         + "uniform sampler2D sampler;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main() {\n"
         + "  gl_FragColor = vec4(texture2D(sampler, v_TexCoordinate).rgb, 1.0);\n"
         + "}\n";
  }

  @Override
  protected void connectTexturesToProgram() {
    mYUVTextureHandle[0] = GLES20.glGetUniformLocation(mProgramHandle, "sampler");
  }

  @Override
  public void setBuffer(byte[] inRgb, byte[] unusedU, byte[] unusedV) {
    if (isDisposed()) return;
    synchronized (glLock) {
      if (isDisposed()) return;
      try {
        egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);
        mBufferRGB = ByteBuffer.wrap(inRgb);
        drawTexture();
      } catch (Throwable t) {
        // drop frame quietly
      }
    }
  }

  @Override
  public void setBufferPtr(long ptr, int size) {
    if (isDisposed()) return;
    synchronized (glLock) {
      if (isDisposed()) return;
      try {
        egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);
        mPtr   = ptr;
        mBytes = getBuffer(ptr, size);
        if (mBytes == null) return;
        mBufferRGB = ByteBuffer.wrap(mBytes);
        drawTexture();
      } catch (Throwable t) {
        // drop frame quietly
      }
    }
  }

  @Override
  public void drawTexture() {
    if (isDisposed() || mBufferRGB == null) return;
    synchronized (glLock) {
      if (isDisposed()) return;

      GLES20.glClearColor(0f, 0f, 1f, 1f);
      GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT | GLES20.GL_DEPTH_BUFFER_BIT);

      GLES20.glUseProgram(mProgramHandle);
      GLES30.glBindVertexArray(vao[0]);

      ByteBuffer[] rgbBuffers = { mBufferRGB };
      loadTexture(rgbBuffers);

      GLES20.glDrawElements(GLES20.GL_TRIANGLES, 6, GLES20.GL_UNSIGNED_INT, 0);

      if (!egl.eglSwapBuffers(eglDisplay, eglSurface)) {
        Log.d(LOG_TAG, String.valueOf(egl.eglGetError()));
      }
    }
  }

  @Override
  protected void loadTexture(ByteBuffer[] buffers) {
    // One RGBA texture bound at unit 0
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, mTextures[0]);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);

    GLES20.glTexImage2D(
        GLES20.GL_TEXTURE_2D,
        0,
        GLES20.GL_RGBA,
        width,
        height,
        0,
        GLES20.GL_RGBA,
        GLES20.GL_UNSIGNED_BYTE,
        buffers[0]
    );

    GLES20.glUniform1i(mYUVTextureHandle[0], 0);
  }
}
