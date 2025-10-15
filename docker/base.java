package com.jci.mediaprocessor.media_processor;

import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLUtils;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;

import javax.microedition.khronos.egl.EGL10;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.egl.EGLContext;
import javax.microedition.khronos.egl.EGLDisplay;
import javax.microedition.khronos.egl.EGLSurface;

public abstract class BaseRenderer {
  static { System.loadLibrary("MediaProcessor"); }

  // KEEP this native until you switch to a DirectByteBuffer path
  public static native byte[] getBuffer(long ptr, int size);

  protected static final String LOG_TAG = "OpenGL.Worker";

  protected final SurfaceTexture texture; // one of these will be non-null
  protected final Surface surface;

  protected int width;
  protected int height;
  protected EGL10 egl;
  protected EGLDisplay eglDisplay;
  protected EGLContext eglContext;
  protected EGLSurface eglSurface;
  protected int mProgramHandle;

  protected final int[] mTextures = new int[3];
  protected int mPositionHandle;
  protected final int[] mYUVTextureHandle = new int[3];

  public BaseRenderer(Surface surface, int width, int height) {
    this.surface = surface;
    this.texture = null;
    this.width = width;
    this.height = height;
  }

  public BaseRenderer(SurfaceTexture texture, int width, int height) {
    this.texture = texture;
    this.surface = null;
    this.width = width;
    this.height = height;
  }

  protected abstract String vertexShader();
  protected abstract String fragmentShader();
  protected abstract void connectTexturesToProgram();
  protected abstract void loadTexture(ByteBuffer[] buffers);
  protected abstract void drawTexture();

  public abstract void setBuffer(byte[] inY, byte[] inU, byte[] inV);
  public abstract void setBufferPtr(long ptr, int size);

  public void initGL() {
    egl = (EGL10) EGLContext.getEGL();
    eglDisplay = egl.eglGetDisplay(EGL10.EGL_DEFAULT_DISPLAY);
    if (eglDisplay == EGL10.EGL_NO_DISPLAY) {
      throw new RuntimeException("eglGetDisplay failed");
    }

    int[] version = new int[2];
    if (!egl.eglInitialize(eglDisplay, version)) {
      throw new RuntimeException("eglInitialize failed");
    }

    EGLConfig eglConfig = chooseEglConfig();
    eglContext = createContext(egl, eglDisplay, eglConfig);

    Object nativeWindow = (surface != null) ? surface : texture;
    eglSurface = egl.eglCreateWindowSurface(eglDisplay, eglConfig, nativeWindow, null);
    if (eglSurface == null || eglSurface == EGL10.EGL_NO_SURFACE) {
      throw new RuntimeException("eglCreateWindowSurface failed: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }

    if (!egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
      throw new RuntimeException("eglMakeCurrent error: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }

    GLES20.glGenTextures(3, mTextures, 0);
  }

  public void initShaders() {
    int v = GLES20.glCreateShader(GLES20.GL_VERTEX_SHADER);
    if (v != 0) {
      GLES20.glShaderSource(v, vertexShader());
      GLES20.glCompileShader(v);
      int[] ok = new int[1];
      GLES20.glGetShaderiv(v, GLES20.GL_COMPILE_STATUS, ok, 0);
      if (ok[0] == 0) { GLES20.glDeleteShader(v); v = 0; }
    }
    if (v == 0) throw new RuntimeException("Error creating vertex shader.");

    int f = GLES20.glCreateShader(GLES20.GL_FRAGMENT_SHADER);
    if (f != 0) {
      GLES20.glShaderSource(f, fragmentShader());
      GLES20.glCompileShader(f);
      int[] ok = new int[1];
      GLES20.glGetShaderiv(f, GLES20.GL_COMPILE_STATUS, ok, 0);
      if (ok[0] == 0) { GLES20.glDeleteShader(f); f = 0; }
    }
    if (f == 0) throw new RuntimeException("Error creating fragment shader: " + fragmentShader());

    mProgramHandle = GLES20.glCreateProgram();
    if (mProgramHandle == 0) throw new RuntimeException("Error creating program.");

    GLES20.glAttachShader(mProgramHandle, v);
    GLES20.glAttachShader(mProgramHandle, f);
    GLES20.glBindAttribLocation(mProgramHandle, 0, "a_Position");
    GLES20.glLinkProgram(mProgramHandle);
    int[] link = new int[1];
    GLES20.glGetProgramiv(mProgramHandle, GLES20.GL_LINK_STATUS, link, 0);
    if (link[0] == 0) {
      GLES20.glDeleteProgram(mProgramHandle);
      throw new RuntimeException("Link failed for program.");
    }

    mPositionHandle = GLES20.glGetAttribLocation(mProgramHandle, "a_Position");
    connectTexturesToProgram();
    GLES20.glUseProgram(mProgramHandle);
  }

  public void initBuffers() {
    float[] vertices = {
      // pos       // tex
       1f,  1f,    1f, 1f,
       1f, -1f,    1f, 0f,
      -1f, -1f,    0f, 0f,
      -1f,  1f,    0f, 1f
    };
    int[] indices = { 0, 1, 2, 0, 2, 3 };

    FloatBuffer vBuf = ByteBuffer.allocateDirect(vertices.length * Float.BYTES)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(vertices);
    vBuf.position(0);

    IntBuffer iBuf = ByteBuffer.allocateDirect(indices.length * Integer.BYTES)
        .order(ByteOrder.nativeOrder()).asIntBuffer().put(indices);
    iBuf.position(0);

    final int[] vbo = new int[1];
    final int[] ebo = new int[1];
    final int[] vao = new int[1];

    GLES30.glGenVertexArrays(1, vao, 0);
    GLES20.glGenBuffers(1, vbo, 0);
    GLES20.glGenBuffers(1, ebo, 0);

    GLES30.glBindVertexArray(vao[0]);
    GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo[0]);
    GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, vertices.length * Float.BYTES, vBuf, GLES20.GL_STATIC_DRAW);
    GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, ebo[0]);
    GLES20.glBufferData(GLES20.GL_ELEMENT_ARRAY_BUFFER, indices.length * Integer.BYTES, iBuf, GLES20.GL_STATIC_DRAW);

    GLES20.glVertexAttribPointer(0, 2, GLES20.GL_FLOAT, false, 4 * Float.BYTES, 0);
    GLES20.glEnableVertexAttribArray(0);
    // If you also use a texcoord attribute, bind it here.
  }

  protected void deinitGL() {
    egl.eglMakeCurrent(eglDisplay, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_CONTEXT);
    egl.eglDestroySurface(eglDisplay, eglSurface);
    egl.eglDestroyContext(eglDisplay, eglContext);
  }

  protected EGLContext createContext(EGL10 egl, EGLDisplay display, EGLConfig cfg) {
    int[] attrib = { 0x3098 /*EGL_CONTEXT_CLIENT_VERSION*/, 2, EGL10.EGL_NONE };
    return egl.eglCreateContext(display, cfg, EGL10.EGL_NO_CONTEXT, attrib);
  }

  protected EGLConfig chooseEglConfig() {
    int[] spec = getConfig();
    int[] count = new int[1];
    EGLConfig[] cfg = new EGLConfig[1];
    if (!egl.eglChooseConfig(eglDisplay, spec, cfg, 1, count) || count[0] == 0) {
      throw new IllegalArgumentException("Failed to choose config: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }
    return cfg[0];
  }

  private int[] getConfig() {
    return new int[] {
      0x3040 /*EGL_RENDERABLE_TYPE*/, 4 /* EGL_OPENGL_ES2_BIT */,
      0x3033 /*EGL_SURFACE_TYPE*/,     0x0004 /* EGL_WINDOW_BIT */,
      0x3024 /*EGL_RED_SIZE*/,         8,
      0x3023 /*EGL_GREEN_SIZE*/,       8,
      0x3022 /*EGL_BLUE_SIZE*/,        8,
      0x3021 /*EGL_ALPHA_SIZE*/,       8,
      0x3025 /*EGL_DEPTH_SIZE*/,       0,
      0x3026 /*EGL_STENCIL_SIZE*/,     0,
      EGL10.EGL_NONE
    };
  }

  /** Swap buffers on the same EGL context that did the draw. */
  protected void present() {
    if (!egl.eglSwapBuffers(eglDisplay, eglSurface)) {
      int err = egl.eglGetError();
      Log.e(LOG_TAG, "eglSwapBuffers error: " + err + " (EGL_BAD_NATIVE_WINDOW is 0x300B)");
    }
  }

  public void onDispose() {
    egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);
    GLES20.glDeleteTextures(3, mTextures, 0);
    present(); // flush any pending work
    deinitGL();
  }
}
