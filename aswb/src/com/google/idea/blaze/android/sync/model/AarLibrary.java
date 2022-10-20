/*
 * Copyright 2018 The Bazel Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.google.idea.blaze.android.sync.model;

import com.android.SdkConstants;
import com.google.common.annotations.VisibleForTesting;
import com.google.common.collect.ImmutableList;
import com.google.devtools.intellij.model.ProjectData;
import com.google.idea.blaze.android.libraries.UnpackedAars;
import com.google.idea.blaze.base.ideinfo.ArtifactLocation;
import com.google.idea.blaze.base.ideinfo.LibraryArtifact;
import com.google.idea.blaze.base.model.BlazeLibrary;
import com.google.idea.blaze.base.model.BlazeProjectData;
import com.google.idea.blaze.base.model.LibraryFilesProvider;
import com.google.idea.blaze.base.model.LibraryKey;
import com.google.idea.blaze.base.sync.workspace.ArtifactLocationDecoder;
import com.google.idea.common.experiments.BoolExperiment;
import com.intellij.openapi.diagnostic.Logger;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.util.text.StringUtil;
import java.io.File;
import java.util.Objects;
import javax.annotation.concurrent.Immutable;
import org.jetbrains.annotations.Nullable;

/**
 * A library corresponding to an AAR file. Has jars and resource directories.
 *
 * <p>AAR Libraries are structured to generate an IntelliJ Library that looks like a library that
 * Studio will generate for an aar in the gradle world. In particular, the classes.jar and res
 * folders are all included as source roots in a single library. One consequence of this is that we
 * don't end up using the blaze sync plugin's handling of jars (which for instance only attaches
 * sources on demand).
 */
@Immutable
public final class AarLibrary extends BlazeLibrary {
  private static final Logger logger = Logger.getInstance(AarLibrary.class);

  @VisibleForTesting
  public static final BoolExperiment exportResourcePackage =
      new BoolExperiment("aswb.aarlibrary.export.res.package", true);

  // libraryArtifact would be null if this aar is created by aspect file. Such aar is generated for
  // generated resources which should not have any bundled jar file.
  @Nullable public final LibraryArtifact libraryArtifact;
  public final ArtifactLocation aarArtifact;

  // resourcePackage is used to set the resource package of the corresponding ExternalLibrary
  // generated by BlazeModuleSystem. Setting resourcePackage to null will create an ExternalLibrary
  // that doesn't have its resource package set.
  //
  // resourcePackage is null when we don't want to export a resource package for the Aar. This would
  // be either if `exportResourcePackage` is turned off, or if there's an issue trying to infer
  // package of the Aar.
  @Nullable public final String resourcePackage;

  public AarLibrary(ArtifactLocation artifactLocation, @Nullable String resourcePackage) {
    this(null, artifactLocation, resourcePackage);
  }

  public AarLibrary(
      @Nullable LibraryArtifact libraryArtifact,
      ArtifactLocation aarArtifact,
      @Nullable String resourcePackage) {
    // Use the aar's name for the library key. The jar name is the same for all AARs, so could more
    // easily get a hash collision.
    super(LibraryKey.fromArtifactLocation(aarArtifact));
    this.libraryArtifact = libraryArtifact;
    this.aarArtifact = aarArtifact;
    this.resourcePackage = exportResourcePackage.getValue() ? resourcePackage : null;
  }

  static AarLibrary fromProto(ProjectData.BlazeLibrary proto) {
    ProjectData.AarLibrary aarLibrary = proto.getAarLibrary();
    return new AarLibrary(
        aarLibrary.hasLibraryArtifact()
            ? LibraryArtifact.fromProto(aarLibrary.getLibraryArtifact())
            : null,
        ArtifactLocation.fromProto(aarLibrary.getAarArtifact()),
        aarLibrary.getResourcePackage());
  }

  @Override
  public ProjectData.BlazeLibrary toProto() {
    ProjectData.AarLibrary.Builder aarLibraryBuilder =
        ProjectData.AarLibrary.newBuilder().setAarArtifact(aarArtifact.toProto());
    if (libraryArtifact != null) {
      aarLibraryBuilder.setLibraryArtifact(libraryArtifact.toProto());
    }

    if (!StringUtil.isEmpty(resourcePackage)) {
      aarLibraryBuilder.setResourcePackage(resourcePackage);
    }
    return super.toProto().toBuilder().setAarLibrary(aarLibraryBuilder.build()).build();
  }

  @Nullable
  public File getLintRuleJar(Project project, ArtifactLocationDecoder decoder) {
    UnpackedAars unpackedAars = UnpackedAars.getInstance(project);
    File lintRuleJar = unpackedAars.getLintRuleJar(decoder, this);
    return (lintRuleJar == null || !lintRuleJar.exists()) ? null : lintRuleJar;
  }

  @Override
  public int hashCode() {
    return Objects.hash(super.hashCode(), libraryArtifact, aarArtifact, resourcePackage);
  }

  @Override
  public LibraryFilesProvider getDefaultLibraryFilesProvider(Project project) {
    return new DefaultAarLibraryFilesProvider(project);
  }

  @Override
  public boolean equals(Object other) {
    if (this == other) {
      return true;
    }
    if (!(other instanceof AarLibrary)) {
      return false;
    }

    AarLibrary that = (AarLibrary) other;
    return super.equals(other)
        && Objects.equals(this.libraryArtifact, that.libraryArtifact)
        && this.aarArtifact.equals(that.aarArtifact)
        && Objects.equals(this.resourcePackage, that.resourcePackage);
  }

  @Override
  public String getExtension() {
    return SdkConstants.DOT_AAR;
  }

  /** An implementation of {@link LibraryFilesProvider} for {@link AarLibrary}. */
  private final class DefaultAarLibraryFilesProvider implements LibraryFilesProvider {
    private final Project project;

    DefaultAarLibraryFilesProvider(Project project) {
      this.project = project;
    }

    @Override
    public String getName() {
      return AarLibrary.this.key.getIntelliJLibraryName();
    }

    @Override
    public ImmutableList<File> getClassFiles(BlazeProjectData blazeProjectData) {
      UnpackedAars unpackedAars = UnpackedAars.getInstance(project);
      File resourceDirectory =
          UnpackedAars.getInstance(project)
              .getResourceDirectory(blazeProjectData.getArtifactLocationDecoder(), AarLibrary.this);
      if (resourceDirectory == null) {
        logger.warn("No resource directory found for aar: " + aarArtifact);
        return ImmutableList.of();
      }

      File jar =
          unpackedAars.getClassJar(blazeProjectData.getArtifactLocationDecoder(), AarLibrary.this);
      // not every aar has class jar attached, do not return non-existent jar to avoid false alarm
      // log.
      if (jar != null && jar.exists()) {
        return ImmutableList.of(resourceDirectory, jar);
      }
      return ImmutableList.of(resourceDirectory);
    }

    @Override
    public ImmutableList<File> getSourceFiles(BlazeProjectData blazeProjectData) {
      // Unconditionally add any linked to source jars. BlazeJarLibrary doesn't do this - it only
      // attaches sources for libraries that the user explicitly asks for. We don't do that for two
      // reasons: 1) all the logic for attaching sources to a library (AttachSourceJarAction,
      // BlazeSourceJarNavigationPolicy, LibraryActionHelper etc) are all tied to Java specific
      // libraries, and 2) So far, aar_imports are primarily used for very few 3rd party
      // dependencies.
      // Longer term, we may want to make this behave just like the Java libraries.
      return UnpackedAars.getInstance(project)
          .getCachedSrcJars(blazeProjectData.getArtifactLocationDecoder(), AarLibrary.this);
    }

    @Override
    public boolean equals(Object other) {
      if (this == other) {
        return true;
      }
      if (!(other instanceof DefaultAarLibraryFilesProvider)) {
        return false;
      }

      DefaultAarLibraryFilesProvider that = (DefaultAarLibraryFilesProvider) other;
      return Objects.equals(project, that.project) && getName().equals(that.getName());
    }

    @Override
    public int hashCode() {
      return Objects.hash(project, getName());
    }
  }
}
