package com.jci.mediaprocessor.media_processor;

import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;

public class RgbRenderer extends BaseRenderer {
  private ByteBuffer mBufferRGB;
  private byte[] mBytes;
  private long mPtr = 0;

  public RgbRenderer(Surface surface, int width, int height) {
    super(surface, width, height);
  }

  public RgbRenderer(SurfaceTexture texture, int width, int height) {
    super(texture, width, height);
  }

  public String vertexShader() {
    return "attribute vec4 a_Position;\n"
         + "attribute vec2 a_TexCoordinate;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main(){\n"
         + "  v_TexCoordinate = a_TexCoordinate;\n"
         + "  gl_Position = a_Position;\n"
         + "}";
  }

  public String fragmentShader() {
    return "precision mediump float;\n"
         + "uniform sampler2D sampler;\n"
         + "varying vec2 v_TexCoordinate;\n"
         + "void main(){\n"
         + "  gl_FragColor = vec4(texture2D(sampler, v_TexCoordinate).rgb, 1.0);\n"
         + "}";
  }

  protected void connectTexturesToProgram() {
    mYUVTextureHandle[0] = GLES20.glGetUniformLocation(mProgramHandle, "sampler");
  }

  public void setBuffer(byte[] inRgb, byte[] unusedU, byte[] unusedV) {
    mBufferRGB = ByteBuffer.wrap(inRgb);
    drawTexture();
  }

  public void setBufferPtr(long ptr, int size) {
    mPtr = ptr;
    mBytes = getBuffer(ptr, size);
    mBufferRGB = ByteBuffer.wrap(mBytes);
    drawTexture();
  }

  public synchronized void drawTexture() {
    // Ensure we are bound to a valid (possibly new) surface before drawing.
    ensureSurfaceIfNeeded();
    if (surfaceLost) return; // wait for onSurfaceAvailable

    GLES20.glClearColor(0f, 0f, 0f, 1f);
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT | GLES20.GL_DEPTH_BUFFER_BIT);

    ByteBuffer[] rgbBuffers = new ByteBuffer[] { mBufferRGB };
    loadTexture(rgbBuffers);

    GLES20.glUseProgram(mProgramHandle);
    GLES20.glDrawElements(GLES20.GL_TRIANGLES, 6, GLES20.GL_UNSIGNED_INT, 0);

    if (!swapBuffers()) {
      Log.w("RgbRenderer", "eglSwapBuffers reported an error; frame not presented");
    }
  }

  protected void loadTexture(ByteBuffer[] buffers) {
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, mTextures[0]);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);

    GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0,
                        GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buffers[0]);

    GLES20.glUniform1i(mYUVTextureHandle[0], 0);
  }
}
